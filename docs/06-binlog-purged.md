---
title: 06 · binlog 被清理，从库断流
date: 2026-11-20
status: 已复现（容器 mysql:8.0.46）
---

> 从库停过一段时间 → 期间主库照常写 → 有人把「看起来没用」的 binlog 清了 →
> 从库再也追不上：**1236，缺的事务在主库上已经不存在**。
>
> 三段写：**问题现象 / 思考方向 / 解决方法**。命令能直接粘进终端，输出是原文。

## 环境构造

常驻环境，镜像全机器只拉一次，之后切实验不重建：

```bash
./lab.sh use 06      # 起一主一从 → 建复制 → 停 IO 线程 → 主库写 + 清 binlog → 放开（首次 30 秒）
./lab.sh use 06 fix  # 自己试过之后再跑，看完整恢复过程
./lab.sh reset 06    # 原地复原（约 5 秒，不重建容器）
```

不用入口脚本也能单独跑（容器定义在仓库根 `compose.yml`，服务 `mysql-binlog-master` / `mysql-binlog-slave`，`profiles: ["06"]`）：

```bash
docker compose --profile 06 up -d              # 只起 06 的两个容器
./scripts/init-replica.sh mysql-binlog-master mysql-binlog-slave   # 建复制
./labs/06-binlog-purged/inject.sh              # 注入
./labs/06-binlog-purged/reset.sh               # 复原
```

环境本身就是考点的一部分：

- **一对一**，不是一主两从。故障发生在「主库和从库之间」，多一个从库只是多等 20 秒初始化。
- 两边都用 `gtid-mode=ON` + `enforce-gtid-consistency=ON`。没有 GTID 的话，这个故障的报错和恢复方式完全不一样（见思考方向第 4 条）。
- 主库 `log-bin=mysql-bin`，`binlog_expire_logs_seconds=604800`（7 天）。生产上这个值决定了「从库最多能落后多久还能救」。
- 端口：主库 13311、从库 13312；账号统一 `root` / `rootpass`，复制账号 `repl` / `replpass`。
- 脚本用 `MYSQL_PWD` 传密码，所以下面的输出里没有 `Using a password ...` 那行告警；
  你自己敲 `-p` 时会多一行，那不是错误。

---

## 一、问题现象

### 现象 1：`Replica_IO_Running: No`，但 `Replica_SQL_Running: Yes`

```bash
$ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Errno|Last_IO_Error'
           Replica_IO_Running: No
          Replica_SQL_Running: Yes
                Last_IO_Errno: 13114
                Last_IO_Error: Got fatal error 1236 from source when reading data from binary log:
'Cannot replicate because the source purged required binary logs. Replicate the missing transactions
from elsewhere, or provision a new replica from backup. Consider increasing the source's binary log
expiration period. The GTID set sent by the replica is 'd673ae42-…:1-29', and the missing
transactions are 'd673ae42-…:30-31''
```

两个坑都在这几行里：

- **SQL 线程还是 Yes**。它把手里的 relay log 应用完就闲着，所以「SQL 线程正常」不代表复制正常。
- **`Last_IO_Errno` 是 13114，不是 1236**。1236 只出现在 `Last_IO_Error` 的正文里。
  监控里写 `Last_IO_Errno = 1236` 会整条漏掉（8.0.46 实测）。

### 现象 2：主库一点事都没有，binlog 只剩一个文件

```bash
# 注入前
$ docker exec -it dfl-06-master mysql -uroot -prootpass -e "SHOW BINARY LOGS"
mysql-bin.000013	352

# 清完「已归档」的日志之后
$ docker exec -it dfl-06-master mysql -uroot -prootpass -e "SHOW BINARY LOGS"
mysql-bin.000015	197

$ docker exec -it dfl-06-master mysql -uroot -prootpass -e "SELECT @@gtid_purged"
d673ae42-…:1-31
```

`@@gtid_purged` 就是「我删到哪儿了」。它比从库的 `@@gtid_executed`（`1-29`）还大，
说明从库要的 `30-31` 这两段已经被删 —— 这是全库唯一能证明「数据真的没了」的地方，
`SHOW BINARY LOGS` 只能看文件名，看不出边界。

### 现象 3：从库业务上直接少数据，但没有任何报错

```bash
$ docker exec -it dfl-06-master mysql -uroot -prootpass -N -B -e "SELECT COUNT(*) FROM demo.t_pk"
124000
$ docker exec -it dfl-06-slave mysql -uroot -prootpass -N -B -e "SELECT COUNT(*) FROM demo.t_pk"
120000
```

少 4000 行。**业务读从库不会报错**，只是读到旧数据 —— 这类故障通常是被业务方
「报表数不对」发现的，不是被监控发现的。

### 现象 4：`Seconds_Behind_Source` 是 `NULL`，不是数字

```bash
$ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Seconds_Behind_Source|Replica_IO_State'
        Seconds_Behind_Source: NULL
             Replica_IO_State:
```

IO 线程没在跑，就没有「落后多少秒」可算，于是给 `NULL`。
**拿 `Seconds_Behind_Source > 300` 做告警，这种情况永远不触发。**

---

## 二、思考方向

### 1. 先分清断的是哪条线程

| 线程 | 干什么 | 挂了会怎样 |
|---|---|---|
| IO 线程 | 连主库、把 binlog 拉到本地 relay log | 从库不再前进，但手上还有货可应用；报错在 `Last_IO_Error` |
| SQL 线程 | 把 relay log 里的事件应用成数据 | 数据不前进，relay log 越积越多；报错在 `Last_SQL_Error` |

本故障断的是 IO 线程，所以 `Last_SQL_Error` 是空的、`Last_IO_Error` 是满的。
两个字段要看对位置，否则会去查从库磁盘、SQL 报错这些根本不存在的东西。

### 2. 1236 读法：从库要的 GTID，主库没有

报错最后半句直接给了答案：`the missing transactions are '…:30-31'`。

```
主库 gtid_executed  …:1-32   ← 我执行过这些
主库 gtid_purged    …:1-31   ← 但 1-31 的 binlog 我删了
从库 gtid_executed  …:1-29   ← 我只有 1-29，要 30-31
```

30-31 对应的 binlog 事件已经不在主库上了 —— 不是网络问题、不是权限问题、不是磁盘问题。

### 3. 「跳过」和「换位点」都救不了

```bash
# 跳过：老版本报 ERROR 1858，8.0.46 上居然接受（退出码 0），但照样没用
$ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SET GLOBAL sql_replica_skip_counter=1"

# 换回按文件位点拉
$ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "
    STOP REPLICA;
    CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='mysql-bin.000013', SOURCE_LOG_POS=352,
      SOURCE_AUTO_POSITION=0;
    START REPLICA;"
$ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Last_IO_Error'
           Replica_IO_Running: No
                Last_IO_Error: Got fatal error 1236 from source when reading data from binary log:
'Could not find first log file name in binary log index file'
```

跳过只能跳过「已经收到、执行时报错」的事件；这里事件根本没到从库，SQL 线程没东西可跳。
换成位点，报错换了句话，结论一样：**那个文件不存在了**。GTID 和位点只是两种定位方式，
都定位不到已经被删掉的数据。

### 5. 所以只能重做全量

缺的 2 个事务已经在主库上被 `PURGE` 掉，任何「从断点续传」的思路都不成立。
唯一能拿到完整数据的地方是**主库现在的数据本身** —— 所以恢复动作天然是
「做一份快照 → 灌到从库 → 从快照的位点接着追」。

大库上这一步是几十分钟到几小时的停机窗口，这才是这个故障真正的代价。

### 6. 三条成因，本质是一条

1. **从库停过**（维护窗口 / 网络断 / IO 线程挂了），期间主库照常写；
2. **`binlog_expire_logs_seconds` 太小**，日志自己到期被删；
3. **有人手工 `PURGE BINARY LOGS` 腾空间**，没先看从库读到哪儿。

**延迟从库最危险**：天然落后几小时，只要 binlog 保留时间 < 延迟时间，一次例行清理就能把它打死。

### 7. 我走错的两条路

- **按 `Last_IO_Errno = 1236` 去告警**：8.0.46 上这个字段是 `13114`，一条都收不到。
- **先怀疑网络**：`Replica_IO_Running: No` 的第一反应是「连不上主库」。可 `Source_Host`
  通、`repl` 能登、`mysqladmin ping` 主库正常 —— 网络能通，是主库回了「你要的东西我没有」。

---

## 三、解决方法

### 1. 现场判断顺序（三眼，两分钟出结论）

```bash
# ① 哪个线程断了、报什么
docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Error'

# ② 主库删到哪儿了（这一步定生死）
docker exec -it dfl-06-master mysql -uroot -prootpass \
  -e "SELECT @@gtid_executed, @@gtid_purged"

# ③ 从库缺多少
docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SELECT @@gtid_executed"
```

`gtid_purged`（主库）> `gtid_executed`（从库）→ 缺的那段已经不可恢复，直接走全量。
反之说明还能靠 binlog 续上，只是复制线程没在跑 —— 那种情况重启复制就行，不用全量。

### 2. 恢复四步（每步都有原因）

```bash
# ① 从库停复制 + 解只读：dump 里有 INSERT，只读状态下灌不进去
docker exec -it dfl-06-slave mysql -uroot -prootpass -e "
  STOP REPLICA; RESET REPLICA ALL;
  SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"

# ② 清空从库的 GTID 记录：新快照自带 GTID_PURGED，不清会撞 ERROR 1840
docker exec -it dfl-06-slave mysql -uroot -prootpass -e "RESET MASTER"

# ③ 主库做一致性快照（不锁表；带上 GTID 位点，这是新起点）
docker exec -it dfl-06-master mysqldump -uroot -prootpass \
  --single-transaction --set-gtid-purged=ON --databases demo > /tmp/demo.sql

# ④ 灌回去，从快照位点续上，再把只读打开
docker exec -i dfl-06-slave mysql -uroot -prootpass < /tmp/demo.sql
docker exec -it dfl-06-slave mysql -uroot -prootpass -e "
  CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql-binlog-master', SOURCE_PORT=3306,
    SOURCE_USER='repl', SOURCE_PASSWORD='replpass', SOURCE_AUTO_POSITION=1;
  START REPLICA;
  SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"
```

`--single-transaction` 走一致性快照、不锁业务表，但**只对 InnoDB 有效**；MyISAM 在 dump 期间会被写坏，
那种库只能停写或用 XtraBackup。`mysqldump` 那句 `Warning: A partial dump ...` 是提醒你只 dump 了一个库，不是错误。

### 3. 实测：从断流到恢复

| 步骤 | 结果 |
|---|---|
| 从库停 IO 线程 | `IO: No`、`SQL: Yes`，主库无感知 |
| 主库写 4000 行 + 切两轮日志 | `mysql-bin.000013 → 000015` |
| `PURGE BINARY LOGS TO 'mysql-bin.000015'` | 只剩 000015（197 字节，空文件） |
| 放开 IO 线程 | 1 秒内 `1236`，缺 `30-31` |
| 业务侧 | 主库 124000 行 / 从库 120000 行 |
| 快照 + 灌回 + 接复制 | 约 5 秒（7.4M 快照），`IO/SQL: Yes`、落后 0 秒、两边都是 124000 |

### 4. 防复发

监控（三条，缺一条就会漏）：

- `Replica_IO_Running` 和 `Replica_SQL_Running` **两个都必须是 Yes**，任一是 No 就告警；
- `Last_IO_Error` / `Last_SQL_Error` **非空**就告警 —— 别按 errno 过滤（见现象 1）；
- `Seconds_Behind_Source` 为 `NULL` 也要告警（IO 线程死了它就是 NULL，数值比较抓不到）。

流程与参数：

- `binlog_expire_logs_seconds` ≥ 「最长可能的复制中断时间」和「延迟从库的延迟时间」；
- `PURGE BINARY LOGS` 前先跑一遍 `SHOW REPLICA STATUS`，确认所有从库的 `Source_Log_File`
  都比要删的文件新；有延迟从库时按延迟算，不按主库文件算；
- 重要库的 binlog 定期归档到对象存储（`mysqlbinlog` 拉走），删了也还能捞回来；
- 大版本升级 / 停机维护计划里，把「从库落后多久」当成一个明确的数字写进去。

---

## 这次没有证明的事

- **大库的恢复耗时**：这里 7.4M 的快照 5 秒搞定。TB 级要用 XtraBackup / CLONE 插件，
  什么时候能追平、要不要限速，这个实验给不出数字。
- **binlog 自己过期**：只演了手工 `PURGE`。`binlog_expire_logs_seconds` 到点自动删的表现一样，
  但没实测过。
- **半同步 / 多级复制**：半同步下主库会等从库 ACK，断流时的写入行为与这里不同。
- **GTID 关闭的库**：报错文案和恢复方式都不同（位点续传、`sql_slave_skip_counter` 真的能用）。

## 自己再答一遍（不看上面）

1. 为什么 `Replica_SQL_Running: Yes` 不能说明复制没问题？
2. `Last_IO_Errno` 不是 1236，那 1236 在哪里？监控该怎么写？
3. 说出「还能续」和「只能全量」的判断依据，一条 SQL。
4. 恢复时为什么要先 `RESET MASTER`？不做会报什么错？
5. `binlog_expire_logs_seconds` 该按什么定？延迟从库为什么更容易死在这上面？
