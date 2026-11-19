---
title: 01 · 主库被 kill -9
date: 2026-11-11
status: 已复现（测试机 Rocky Linux 10.2 / Docker mysql:8.0.46 上实跑）
---

> 一句话：主库被强杀之后，从库多久发现、多久自愈、中间会不会丢数据。
> 下面固定三段写：**问题现象 / 思考方向 / 解决方法**，命令和报错都是这台机器上跑出来的原文。

## 怎么先把它跑起来

```bash
./lab.sh up          # 起环境（一主两从，首次约 1 分钟）
./lab.sh use 01      # 建好复制关系 → kill -9 主库 → 打印从库当时的报错（10 秒）
./lab.sh reset 01    # 复原：等主库起来，重新接上复制（4 秒）
```

## 环境

- 镜像 `mysql:8.0`（8.0.46-1.el9），docker compose 一主两从，GTID + ROW binlog
- 主库 server-id=1，从库 2/3，`SOURCE_AUTO_POSITION=1`
- 从库 `super_read_only=ON`（建好复制之后才打开，原因见解决方法第 4 条）
- 注入方式：从**宿主 namespace** 杀容器的 1 号进程（不是容器内 kill）

---

## 一、问题现象

### 现象 1：容器被杀，退出码 137

```bash
$ docker inspect -f '{{.State.ExitCode}} {{.RestartCount}}' dfl-master
137 2
```

`137 = 128 + 9`，就是 SIGKILL。`RestartCount` 加一，说明 docker 按 `restart: unless-stopped` 把它重新拉起来了。

### 现象 2：从库 1 秒内掉到 `Connecting`，报错 111

```bash
$ docker exec -it dfl-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" | grep -E 'Running|Last_IO_Error'
Replica_IO_Running: Connecting
Replica_SQL_Running: Yes
Last_IO_Error: Error reconnecting to source 'repl@mysql-master:3306'.
  This was attempt 1/86400, with a delay of 60 seconds between attempts.
  Message: Can't connect to MySQL server on 'mysql-master:3306' (111)
```

`111 = ECONNREFUSED`：端口上没有进程监听，不是权限问题、不是密码错。

### 现象 3：`Seconds_Behind_Source` 是 `NULL`，不是 `0`

```bash
$ docker exec -it dfl-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" | grep Seconds_Behind
Seconds_Behind_Source: NULL
```

**这是最容易骗过监控的一行。** IO 线程没连上，这个值就退化成 `NULL`，任何 `> 60 就告警` 的规则都会漏掉它。

### 现象 4：主库 2 秒就活了，业务却感觉断了一分钟

```bash
$ docker logs dfl-master 2>&1 | grep -E 'XA crash recovery|ready for connections' | tail -3
[Note] [MY-012469] [InnoDB] Starting XA crash recovery...
[Note] [MY-012470] [InnoDB] XA crash recovery finished.
[System] [MY-010931] [Server] /usr/sbin/mysqld: ready for connections. Version: '8.0.46'  port: 3306
```

主库 T+1.8s 就能接受连接了，但从库要等到 T+60s 左右才重新连上 —— 中间那 58 秒的"复制中断"是**重试周期**造成的，不是主库没起来。

---

## 二、思考方向

### 1. 先分清"杀"的三种语义

| 写法 | 进程死没死 | 等价于 |
|---|---|---|
| 容器内 `kill -9 1` | **没死** | 内核会丢弃同一 PID namespace 内发给 1 号进程的 SIGKILL |
| `docker kill --signal=SIGKILL dfl-master` | 死了 | **手动停止**，`restart` 策略不介入，容器不会被拉起 |
| `kill -9 $(docker inspect -f '{{.State.Pid}}' dfl-master)` | 死了 | 宿主机 OOM killer / 机器掉电，docker 会按策略重启 |

只有第三种才是"故障"，前两种演出来的东西会骗人：第一种什么都看不出，第二种容器躺着不起来、看起来像"重启策略失效"。

### 2. 从库断的是哪条线

- IO 线程连不上主库 → `Replica_IO_Running: Connecting`，`Last_IO_Error` 报 111
- SQL 线程还有 relay log 可读 → 依然是 `Yes`，把积压的 relay log 追平后停在 `waiting for more updates`

所以"复制断了"要看两个线程，只盯 SQL 线程会以为一切正常。

### 3. 为什么 60 秒才回来：`SOURCE_CONNECT_RETRY`

报错里那句 `with a delay of 60 seconds between attempts` 就是答案：重连失败后 IO 线程睡 60 秒再试，默认值 60。主库 1.8 秒活过来，也得等这个周期到点。

### 4. 为什么不需要人工补位点：GTID

`SOURCE_AUTO_POSITION=1` 时，重连后从库拿自己的 `Retrieved_Gtid_Set` 和主库 `gtid_executed` 一比，缺哪段补哪段。**这是 GTID 相对 file+position 的核心价值**：不用记位点、不用人工 `CHANGE ... MASTER_LOG_FILE`。

### 5. 「没丢数据」这次只是没机会丢

本次 kill 时主库上没有未提交事务，也没有在途的半同步确认，所以看不出差异。要证明"强杀会不会丢已提交事务"，得制造在途事务再杀 —— 见文末「这次没有证明的事」。

---

## 三、解决方法

### 1. 现场判断顺序（三眼）

```bash
# ① 主库活了吗
$ docker ps --filter name=dfl-master --format '{{.Status}}'
Up 30 seconds (healthy)

# ② 从库两个线程的状态
$ docker exec -it dfl-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error'

# ③ GTID 差多少（追平了就没有输出）
$ docker exec -it dfl-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Retrieved_Gtid_Set|Executed_Gtid_Set'
```

### 2. 多数情况什么都不用做

`Replica_IO_Running: Connecting` 只说明"正在重试"。等一个 `SOURCE_CONNECT_RETRY` 周期（60 秒）它自己就回来了，`Retrieved_Gtid_Set` 会自动补齐。

真要人工介入只有三种理由：`Last_IO_Error` 是认证/权限错（不是 111）、主库 binlog 已被 purge（报 1236）、从库 SQL 线程报错停了（`Replica_SQL_Running: No`）。

### 3. 想更快自愈就调参数，但要算代价

```sql
-- 从库上
STOP REPLICA IO_THREAD;
CHANGE REPLICATION SOURCE TO SOURCE_CONNECT_RETRY = 10;
START REPLICA IO_THREAD;
```

从 60 秒缩到 10 秒，故障时恢复更快；代价是主库长时间不可用时，重试风暴更密。多数场景**保持 60 秒 + 好监控**比调参数更划算。

### 4. 建环境时的坑：`super_read_only` 不能提前开

第一版把 `super-read-only=ON` 直接写进 `slave.cnf`，容器起不来：

```
ERROR 1290 (HY000): The MySQL server is running with the --super-read-only option
so it cannot execute this statement
```

因为官方镜像的 entrypoint 初始化时要执行 `ALTER USER root@localhost IDENTIFIED BY ...`，`super_read_only` 连 super 用户都拦。正确做法是**建好复制之后**再 `SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;`（`scripts/init-replica.sh` 就是这么做的）。

### 5. 防复发（监控是重点）

- **不能只看 `Seconds_Behind_Source > 阈值`。** 复制断了这个值是 `NULL`，任何比较都会漏。必须单独盯：
  - `Replica_IO_Running != Yes` → 立即告警（P1）
  - `Replica_SQL_Running != Yes` → 立即告警（P1）
  - `Seconds_Behind_Source IS NULL` → 视为复制中断
  - mysqld_exporter 里对应 `mysql_slave_status_slave_io_running`、`mysql_slave_status_seconds_behind_master`，后者为 NaN 时别被 `avg()` 抹平
- **流程**：主库重启/切换后，必须显式确认三件事 —— 从库 IO 线程状态、GTID 是否追平、有没有 `Last_IO_Error`。别等业务反馈"数据不对"。

### 6. 一次演练的时间线

| 时间 | 发生了什么 | 证据 |
|---|---|---|
| T+0s | 宿主上 `kill -9` 掉容器 PID 1 | `ExitCode=137`，`RestartCount` 1→2 |
| T+0s | 从库 IO 线程立刻断开，转入 `Connecting` | 第 1 秒的 `SHOW REPLICA STATUS` 已是 Connecting |
| T+1s | docker 按 `restart: unless-stopped` 拉起容器 | 日志 `Entrypoint script for MySQL Server 8.0.46 started` |
| T+1.4s | InnoDB 初始化 + XA crash recovery | `Starting XA crash recovery...` → `finished.`（间隔 7ms） |
| T+1.8s | 主库可接受连接 | `ready for connections ... port: 3306` |
| T+1.8s ~ T+60s | 从库仍然 Connecting，不会立刻重连 | 报错里的 `delay of 60 seconds between attempts` |
| T+60s 左右 | 重试周期到，自动重连成功 | `Replica_IO_Running: Yes`，GTID 自动补齐 |

---

## 这次实验没有证明的事

**没有丢数据 ≠ 零丢失。** 本次 kill 时主库上没有未提交事务，所以看不出问题。要真验证，得这么做：

1. 主库开一个事务，`COMMIT` 后立刻 kill（用 `--init-command` 或脚本卡时序）
2. 重连后比对主库 `@@gtid_executed` 与从库 `Retrieved_Gtid_Set`
3. 打开半同步（`rpl_semi_sync_source_enabled`）再重复一次，看差异

这是实验 03 的内容。

## 自己再答一遍（不看上面）

1. 从库发现主库没了，用了多久？靠什么发现的（心跳？TCP 断开？）
2. 主库 2 秒就恢复服务，为什么从库还要等将近一分钟？
3. `Seconds_Behind_Source = NULL` 和 `= 0` 分别代表什么？哪种更危险？
