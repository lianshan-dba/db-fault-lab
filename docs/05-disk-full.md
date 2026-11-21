---
title: 05 · 磁盘写满 + 慢日志句柄未释放
date: 2026-11-19
status: 已复现（容器 mysql:8.0.46；另有 8.4.11 真机对照）
---

# 背景

生产环境中，磁盘满了，业务写不进去，把大日志删除之后，磁盘没有释放出来。

**df检查没有释放，du检查已经释放了**

```
[root@db01 db-fault-lab]# docker exec -it dfl-05-disk-full  rm -rf /var/lib/mysql/slow.log
[root@db01 db-fault-lab]# docker exec -it dfl-05-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           768M  768M     0 100% /var/lib/mysql
406M	/var/lib/mysql
```

**单条数据插入没有问题，但是创建表和批量插入会报错。**

```
[root@db01 db-fault-lab]# docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo \
>     -e "INSERT INTO t_big(pad) VALUES (REPEAT('y',1100)); SELECT ROW_COUNT() AS affected_rows;"
mysql: [Warning] Using a password on the command line interface can be insecure.
+---------------+
| affected_rows |
+---------------+
|             1 |
+---------------+
[root@db01 db-fault-lab]#  docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo \
>     -e "INSERT INTO t_big(pad) SELECT REPEAT('y',1100) FROM information_schema.columns LIMIT 5000"
mysql: [Warning] Using a password on the command line interface can be insecure.
ERROR 1114 (HY000) at line 1: The table 't_big' is fullERROR 1114 (HY000) at line 1: The table 't_big' is full
[root@db01 db-fault-lab]# docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo \
>     -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB"
mysql: [Warning] Using a password on the command line interface can be insecure.
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

**检查慢日志状态，是开启状态。**

```
[root@db01 db-fault-lab]# docker exec -it dfl-05-disk-full mysql -uroot -prootpass -e "show variables like 'slow_query_log'"
mysql: [Warning] Using a password on the command line interface can be insecure.
+----------------+-------+
| Variable_name  | Value |
+----------------+-------+
| slow_query_log | ON    |
+----------------+-------+
```



# 环境构造

常驻环境，镜像全机器只拉一次，之后切实验不重建：

```bash
./lab.sh up          # 第一次：备镜像（约 1 分钟）；以后必跳过
./lab.sh use 05      # 起容器 → 灌慢日志 → 填满盘 → 打印命令和报错（首次 30 秒）
./lab.sh use 05 fix  # 自己试过之后再跑，对答案
./lab.sh reset 05    # 原地复原，接着练下一轮（1 秒，不重建容器）
```

不用入口脚本也能单独跑（容器定义在仓库根 `compose.yml`，服务 `mysql-disk-full`，`profiles: ["05"]`）：

```bash
docker compose --profile 05 up -d          # 只起 05 的服务，不连带 01/02
./labs/05-disk-full/inject.sh              # 注入 + 打印现场和你该敲的命令
./labs/05-disk-full/reset.sh               # 原地复原
```

环境本身就是考点的一部分：`/var/lib/mysql` 挂在 **768M tmpfs** 上（不用 named volume，否则造 `ENOSPC` 得先填满你自己的盘），初始化后占 130M。

同一套故障在真机上也跑过（8.4.11 / loop + ext4 974M）：`ENOSPC`、`df`/`du` 分叉、`(deleted)` 句柄这三件事行为完全一致，真机只多两个 SELinux 的坑 —— 不处理 mysqld 读不了 datadir、bind 直接被拒：

```bash
chcon -R -t mysqld_db_t /mnt/labdisk
semanage port -a -t mysqld_port_t -p tcp 3310
```

---



# 故障分析

**df检查没有释放，du检查已经释放了**

`df` 读文件系统元数据，统计**已分配的块** → 被删但被占用的块还算在内，du是统计能看到的文件。

说明有进程还在持有已经删除的文件，导致空间还没回收。

```
[root@db01 db-fault-lab]#  docker exec -u mysql -it dfl-05-disk-full ls -l /proc/1/fd | grep 'slow\.log'
l-wx------. 1 mysql mysql 64 Nov 21 03:27 26 -> '/var/lib/mysql/slow.log (deleted)'
```

可以看到mysql还在持有的。

现在需要空间，又不能重启数据库的情况下，思考如何清理这部分数据呢。

解决步骤：

```
# ① 先确认是真的盘满：df 和 du 一起看，两个数对不上就去 /proc 找 (deleted)
$ df -h /var/lib/mysql; du -sh /var/lib/mysql

# ② 能安全回收的先回收（binlog / 旧 relay log / 旧备份）
$ mysql -uroot -p -e "PURGE BINARY LOGS BEFORE NOW() - INTERVAL 1 DAY"

# ③ 慢日志这一类的：关掉持有者，让空间回来（下面三种任选一种）
$ mysql -uroot -p -e "SET GLOBAL slow_query_log=OFF"           # 最快，一条 SQL
$ mv /var/lib/mysql/slow.log /var/lib/mysql/slow.log.1 && mysql -uroot -p -e "FLUSH SLOW LOGS"
$ : > /var/lib/mysql/slow.log                                   # truncate，救急用

# ④ 验证空间真的回来了，而且实例没重启
$ df -h /var/lib/mysql
$ mysql -uroot -p -e "SHOW GLOBAL STATUS LIKE 'Uptime'"         # 单调增长 = 没重启
```

关闭慢日志之后记得开启

```
mysql -uroot -p -e "SET GLOBAL slow_query_log=ON" 
```



# 总结

**配置**

- 慢日志放**独立挂载点**并给容量上限 —— 代价是本故障链被掩盖（日志写满挤不到 datadir），取舍要想清楚
- `logrotate` 配 `postrotate mysqladmin flush-logs`，**不要用 `copytruncate`**（和写入偏移打架）
- `long_query_time` 不低于 1；`log_queries_not_using_indexes` 必须配 `log_throttle_queries_not_using_indexes` + `min_examined_row_limit`
- 大 SQL 治理：批量 `INSERT` 拆批、`IN` 列表控长度 —— 一条 500KB 的 SQL 在慢日志里就是一条 500KB 的记录

**监控（要能直接落地，不要"加强监控"）**

- 每个挂载点的使用率 + **增速**（不是只看当前大小）
- `lsof +L1` / `SELECT ... FROM performance_schema` 拿"已删除但仍被打开"的字节数
- error log 里 `errno: 28` / `MY-010907` 单独告警 —— 这条先于业务报错
- 慢日志文件的日增量，突增就是大 SQL 或阈值被人改了

**不要做**

- `rm` 完就以为处理完了
- 用"能不能 INSERT 一条"判断盘满
- 盘满时立刻重启 —— 很可能起不来
- `kill -9 mysqld` —— crash recovery 比正常重启慢得多



# 问题复盘

1. `df` 显示 100%，`du` 加起来只有一半。这两个数差在哪，说明什么？
2. 删掉慢日志之后 `df` 会降吗？为什么？
3. 磁盘满时 `INSERT` 一条成功了，能不能说明盘没满？为什么？
4. 慢日志在独立盘上，那个盘满了，业务会挂吗？这个答案会怎么改变你的监控设计？
5. 除了关慢日志，还有哪两种方式能让那个 inode 的 `refcount` 归零？各自的代价是什么？
6. 盘满时为什么不能重启？「起不来」具体卡在哪一步？
