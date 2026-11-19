---
title: 05 · 磁盘写满 + 慢日志句柄未释放
date: 2026-11-19
status: 已复现（测试机 Rocky Linux 10.2 / Docker mysql:8.0.46；另有 8.4.11 真机对照）
---

> 一句话说完：盘满了 → 业务写不进去 → 把大日志删了 → **`df` 一点都不降** → 不重启把空间要回来。
>
> 下面固定三段写：**问题现象 / 思考方向 / 解决方法**。
> 每段都给能直接粘进终端的命令和它真实的输出，不转述、不"大概"。

## 怎么先把它跑起来

```bash
./lab.sh up          # 第一次：备镜像 + 起环境（约 1 分钟）；以后几秒
./lab.sh use 05      # 切到这个故障：灌慢日志 → 填满盘 → 打印命令和报错（2 秒）
./lab.sh use 05 fix  # 自己试过之后再跑，对答案
./lab.sh reset 05    # 原地复原，接着练下一轮（1 秒，不重建容器）
```

不想用入口脚本，手工三行也一样：

```bash
cd mysql
docker compose up -d mysql-disk-full      # 只起这一个实例（宿主 13309）
./inject/disk-full.sh                     # 注入 + 打印现场和你该敲的命令
./inject/disk-full-reset.sh               # 原地复原
```

## 环境

同一套机制在两种环境各跑一遍，数字对得上：

| | 容器版（可复现） | 真机版（验证行为） |
|---|---|---|
| MySQL | 8.0.46 | 8.4.11 |
| 盘 | tmpfs 768M | loop + ext4 974M |
| 初始化后占用 | 130M | 119M |
| 结论 | 完全一致 | 完全一致 |

真机那台是 4C/15G 的测试机（Rocky Linux 10.2），**SELinux Enforcing**。要在真机复刻多两个坑：

```bash
chcon -R -t mysqld_db_t /mnt/labdisk                  # 否则 mysqld 读不了 datadir
semanage port -a -t mysqld_port_t -p tcp 3310         # 否则 bind 直接被拒
```

容器里没有 SELinux，脚本不处理这两步。`ENOSPC`、`df`/`du` 的分叉、`(deleted)` 句柄这三件事在 tmpfs 和 ext4 上行为完全一样，真机只多给了 SELinux 和块设备。

---

## 一、问题现象

### 现象 1：盘满了，`df` 和 `du` 都对得上

```bash
$ docker exec -it dfl-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
tmpfs           768M  766M  2.1M 100% /var/lib/mysql
766M	/var/lib/mysql
```

**两个数相等是正常的，这时候还什么都没删。** 很多人在这步就以为脚本没生效 —— 分叉要到删除之后才出现。

注满这块盘的是两个文件：慢日志 363M、filler 273M（真实场景里后者是 binlog 暴涨 / 大事务 / 磁盘临时表）。

### 现象 2：单条 INSERT 能成功，批量插入和建表立刻失败

> 下面每条 `mysql` 命令前面都会多打印一行 `mysql: [Warning] Using a password on the command line
> interface can be insecure.` —— 那是"命令行里带密码"的提示，不是错误，忽略它。

```bash
# 单行：成功，屏幕上一片空白
$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \
    -e "INSERT INTO t_big(pad) VALUES (REPEAT('y',1100))"
（无输出 = 成功。非交互模式下 mysql 不打印 Query OK）

# 想看行数就自己选出来
$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \
    -e "INSERT INTO t_big(pad) VALUES (REPEAT('y',1100)); SELECT ROW_COUNT() AS affected_rows;"
affected_rows
1

# 批量 5000 行：要扩 .ibd，失败
$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \
    -e "INSERT INTO t_big(pad) SELECT REPEAT('y',1100) FROM information_schema.columns LIMIT 5000"
ERROR 1114 (HY000) at line 1: The table 't_big' is full

# 建表：失败，但报的是另一个错号
$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \
    -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB"
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

单行能成功，是因为已有数据页里还有空隙，塞得下；批量插入要扩 extent、建表要写新的 `.ibd`，一扩就撞墙。**所以「能不能插一条」永远不能用来判断盘满。**

### 现象 3：删掉慢日志，`df` 一点没降

```bash
$ docker exec -it dfl-disk-full rm -f /var/lib/mysql/slow.log
$ docker exec -it dfl-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
tmpfs           768M  766M  2.1M 100% /var/lib/mysql     ← 一点没降
406M	/var/lib/mysql                                   ← 掉了 362M
```

删除确实生效了（`ls` 看不到文件了），空间却没回来。这就是整个实验的核心。

### 现象 4：服务端日志只有一条，慢日志还是 ON

```bash
$ docker logs dfl-disk-full 2>&1 | grep -E 'errno: 28|MY-010907' | tail -3
[ERROR] [MY-010907] [Server] Error writing file '/var/lib/mysql/slow.log' (errno: 28 - No space left on device)

$ docker exec -it dfl-disk-full mysql -uroot -prootpass -e "SHOW VARIABLES LIKE 'slow_query_log'"
Variable_name	Value
slow_query_log	ON
```

**8.0.46 和 8.4.11 都不会因为写失败自己关慢日志**，只报一条就继续跑。所以那个 fd 会一直挂着，盘满之后句柄不会自己消失。

### 现象 5：谁还开着这个文件

```bash
# 错误写法：默认是 root，读不到 mysqld 的 fd
$ docker exec -it dfl-disk-full ls -l /proc/1/fd | grep 'slow\.log'
ls: cannot open directory '/proc/1/fd': Permission denied

# 正确写法：以 mysqld 自己的身份去看
$ docker exec -u mysql -it dfl-disk-full ls -l /proc/1/fd | grep 'slow\.log'
l-wx------  1 mysql mysql 64 Nov 19 15:53 36 -> /var/lib/mysql/slow.log (deleted)
```

`(deleted)` 是关键。顺手还会看到几条 `/tmp/#NNN (deleted)`，那是 InnoDB 的临时文件，一直在、也很小，不是嫌疑对象。

---

## 二、思考方向

### 1. 先把「占用」分成三类

盘满的时候不是所有空间都能立刻要回来，先分类再动手：

| 类型 | 例子 | 怎么处理 |
|---|---|---|
| MySQL 能自己回收 | purge 过的 binlog、旧的 relay log | `PURGE BINARY LOGS`，不要 `rm` 文件（索引会不一致） |
| 只能删文件 | 慢日志、错误日志、旧备份、core dump | `rm`，但**要看有没有进程开着** |
| `rm` 也没用 | 被进程持有的已删除文件 | 关掉持有者（本实验就是这一类） |

第三类是这个故障的全部难点：`rm` 之后 `df` 不动，人会以为"删错了"或"文件系统坏了"。

### 2. 删除 ≠ 关闭：两个引用计数

Linux 回收一个文件的数据块，要**同时**满足两个条件：

- `i_nlink == 0`：没有目录项指向这个 inode（`rm` 干的事）
- `refcount == 0`：没有进程持有它的 fd（`close` 干的事）

`rm` 之后 `nlink` 立刻归零，但 mysqld 的 fd 还开着，`refcount` 还是 1，条件缺一，一个块都不回收。

### 3. `df` 和 `du` 统计的不是一件事

- `df` 读文件系统元数据，统计**已分配的块** → 被删但被占用的块还算在内
- `du` 遍历目录树，统计**能看到的文件** → 那个文件已经没有路径了，看不到

所以两个数一旦对不上，只有一个解释：**有进程持着已删除的 inode**。这不是文件系统的锅。

### 4. 我走错的四条路（都别重走）

- **去怀疑文件系统。** 查 `mount`、`dumpe2fs`，怀疑 loop 设备、怀疑挂载丢了 —— 全错。岔路口是同时看 `df` 和 `du`。
- **用单行 INSERT 判断盘满。** 返回成功，一度以为盘已经好了，直到批量插入报 `ERROR 1114` 才发现被骗。
- **`grep -i slow` 把自己骗了。** 关掉慢日志后想确认句柄没了，`grep -i slow` 输出一整屏 fd，其实匹配到的是**路径名** `/mnt/labdisk/`。要写 `grep 'slow\.log'` 并看有没有 `(deleted)`。重开慢日志会有一个**新的** fd 指向真实文件，那是正常的。
- **`/proc/1/fd` 权限不足，看起来像"没有句柄"。** root 读 mysqld 的 fd 被拒，输出 `Permission denied`；如果顺手加了 `2>/dev/null`，就变成什么都没有 —— 和"确实没有"在输出上一模一样。必须 `-u mysql`。

### 5. 为什么不能重启

重启要写盘的地方太多了：新建 binlog、InnoDB 打开 redo、`ibtmp1`/`tmpdir`、pid 文件，还有 crash recovery 自己的临时文件。盘满时这些全部可能失败，**初始化阶段就退出，实例起不来**。而且 `shutdown` 本身也可能卡住。

所以处置方向从一开始就应该是「不重启，把句柄关掉」，而不是「重启一下试试」。

---

## 三、解决方法

### 1. 处置顺序（全程不重启）

```bash
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

# ⑤ 腾出空间之后再扩盘，别把扩盘当第一动作
```

### 2. 三种删日志方式的差别（只有一种是对的）

| 做法 | 空间立即释放 | 说明 |
|---|---|---|
| `rm slow.log` | **否** | fd 还在，白删（本实验的现场） |
| `: > slow.log` | 是 | truncate 不改 inode；紧急可用，官方不支持，可能留稀疏空洞 |
| `mv` + `FLUSH SLOW LOGS` | 是 | **标准做法**，旧 fd 关闭、新 inode 建立，需要 `RELOAD` 权限 |

本实验用的是第四种：`SET GLOBAL slow_query_log=OFF` 再 `ON`。它和 `mv`+`FLUSH` 等价（都是关 fd、开新文件），好处是不用碰文件系统。

### 3. 实测：空间怎么回来的

```
关慢日志前：df 768M/100%，du 406M（删了 363M 的慢日志，du 掉了，df 没动）
SET GLOBAL slow_query_log=OFF 之后：df 768M → 406M（363M 立刻回收）
清掉 filler 之后：df 133M
重开慢日志：新 slow.log 1.3K
写入恢复：INSERT ... 3548 rows affected
```

全程 `Uptime` 单调增长，**没有重启**。

### 4. 一次真机演练的时间线（974M ext4）

| 时间 | 发生了什么 | 证据 |
|---|---|---|
| 21:18:47 | 独立实例初始化开始 | `MySQL Server Initialization - start` |
| 21:18:51 | 初始化结束，占用 119M | `du -sh data` |
| 21:19:00 | 实例就绪，监听 3310 | `ready for connections` |
| 21:19:1x | 灌入 780KB 长 SQL × 600 条 | 慢日志 447M，盘到 64% |
| 21:19:2x | filler 补刀 378M | `df` **958M / 100%** |
| 21:19:27 | 建表失败 | `ERROR 3675 ... disk is full` |
| 21:19:35 | 慢日志首次写失败 | `[ERROR] [MY-010907] ... errno: 28` |
| 21:19:4x | `rm slow.log` | `df` **仍 958M**，`du` 掉到 511M |
| 21:19:4x | 确认 fd 持有已删除 inode | `fd → slow.log (deleted)` |
| 21:20:0x | `SET GLOBAL slow_query_log=OFF` | `df` **511M**，447M 回来 |
| 21:20:1x | 清 filler、阈值改回、重开 | 新 `slow.log` 1.3K，`df` 149M |
| 21:20:2x | 业务恢复 | `INSERT ... 3554 rows affected` |

### 5. 防复发

**配置**

- 慢日志放**独立挂载点**并给容量上限 —— 但这会掩盖本故障链（见思考方向第 5 点），取舍要想清楚
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

---

## 这次没有证明的事

原定的"binlog 和 redo 谁先写不进去"没有测。这次是 filler 一次性打满的，没观察 redo 循环写和 binlog 增长在同一块盘上抢空间的先后顺序。

下一步：把 `innodb_redo_log_capacity` 调小、开 `sync_binlog=1`，缓慢逼近 `ENOSPC`，看谁先报错。这是 05 的另一半。

## 自己再答一遍（不看上面）

1. `df` 显示 100%，`du` 加起来只有一半。这两个数差在哪，说明什么？
2. 删掉慢日志之后 `df` 会降吗？为什么？
3. 磁盘满时 `INSERT` 一条成功了，能不能说明盘没满？为什么？
4. 慢日志在独立盘上，那个盘满了，业务会挂吗？这个答案会怎么改变你的监控设计？
5. 除了关慢日志，还有哪两种方式能让那个 inode 的 `refcount` 归零？各自的代价是什么？
6. 盘满时为什么不能重启？「起不来」具体卡在哪一步？
