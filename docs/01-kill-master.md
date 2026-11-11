---
title: 01 · 主库被 kill -9
date: 2026-11-11
status: 已复现（在本机 Ubuntu 24.04 / mysql:8.0.46 上实跑）
---

> 这个实验要回答的问题不是"从库会不会挂"，而是**从库用多久才发现、用多久才恢复、中间会不会丢数据**。
> 下面所有时间戳和报错都是真实跑出来的，不是抄文档。

## 环境

- 镜像：`mysql:8.0`（8.0.46-1.el9），docker compose 一主两从，GTID + ROW binlog
- 主库 server-id=1，从库 2/3，`SOURCE_AUTO_POSITION=1`
- 从库 `super_read_only=ON`（由 `scripts/init-replica.sh` 在建好复制后打开）
- 触发方式：`inject/kill-master.sh`

## 现象（原始报错，原文照抄）

从库 1 秒内就变成 `Connecting`：

```
Replica_IO_Running: Connecting
Replica_SQL_Running: Yes
Seconds_Behind_Source: NULL
Last_IO_Error: Error reconnecting to source 'repl@mysql-master:3306'.
  This was attempt 1/86400, with a delay of 60 seconds between attempts.
  Message: Can't connect to MySQL server on 'mysql-master:3306' (111)
Last_IO_Error_Timestamp: 261111 05:12:37
```

注意这一行：**`Seconds_Behind_Source: NULL`，不是 `0`**。这是最容易骗过监控的地方，下面「防复发」里展开。

## 时间线

| 时间 | 发生了什么 | 证据 |
|---|---|---|
| T+0s | 宿主上 `kill -9` 掉容器的 PID 1 | 容器 `ExitCode=137`，`RestartCount` 1→2 |
| T+0s | 从库 IO 线程立刻断开，转入 `Connecting` | 第 1 秒的 `SHOW REPLICA STATUS` 已是 Connecting |
| T+1s | docker 按 `restart: unless-stopped` 拉起容器 | 日志 `Entrypoint script for MySQL Server 8.0.46 started` |
| T+1.4s | InnoDB 初始化 + XA crash recovery | `Starting XA crash recovery...` → `XA crash recovery finished.`（间隔 7ms） |
| T+1.8s | 主库可接受连接 | `ready for connections ... port: 3306` |
| T+1.8s ~ T+60s | **从库仍然 Connecting**，不会立刻重连 | 报错里的 `delay of 60 seconds between attempts` |
| T+60s 左右 | 下一个重试周期到，自动重连成功 | `Replica_IO_Running: Yes`，GTID 自动补齐，无需人工干预 |

**核心结论：主库 2 秒就回来了，但业务看起来"复制的坑"要持续 60 秒。** 生产上"主库明明起来了，从库还在 Connecting"这个经典疑问，答案就在 `SOURCE_CONNECT_RETRY`（默认 60 秒）的第一次重试还没到。

## 排查过程（包括走错的路）

这个实验我踩了两个坑，都值得记下来，因为它们是"看起来做了什么，其实什么也没发生"的典型：

1. **在容器里 `kill -9 1` 完全无效。** 内核会丢弃从同一 PID namespace 内发给 1 号进程的 SIGKILL —— 容器不退出、主库不重启、从库照旧连得上，脚本跑完一切"正常"。第一版脚本就是这么写的，观察了 5 秒全是 `Yes`，差点当成"MySQL 抗住了"。
2. **改成 `docker kill --signal=SIGKILL` 后容器死了，但没被拉起来。** `RestartCount=0`、`status=exited`。原因是 `docker kill` 和 `docker stop` 一样算"手动停止"，`restart: unless-stopped` 不会介入。
   → 正确做法：`kill -9 $(docker inspect -f '{{.State.Pid}}' dfl-master)`，从宿主 namespace 直接杀容器的 1 号进程，这才等价于 OOM killer / 机器掉电。

顺带一个启动期的坑：从库最初在 `slave.cnf` 里写了 `super-read-only=ON`，容器直接 `Exit(1)`：

```
ERROR 1290 (HY000): The MySQL server is running with the --super-read-only option
so it cannot execute this statement
```

因为官方镜像的 entrypoint 初始化时要执行 `ALTER USER root@localhost IDENTIFIED BY ...`，`super_read_only` 连 super 用户都拦。改成建好复制后再 `SET GLOBAL` 打开。

## 根因

- 直接原因：主库进程被强杀，TCP 连接被内核关闭，从库 IO 线程读连接报 `error 111 (Connection refused)`。
- 为什么能自动好：`SOURCE_AUTO_POSITION=1`（GTID），重连后从库把 `Retrieved_Gtid_Set` 和主库 `gtid_executed` 一比，缺哪段补哪段。**不需要人工找 binlog 位点，这是 GTID 相对 file+position 的核心价值。**
- 为什么慢：`SOURCE_CONNECT_RETRY` 默认 60 秒，重连失败后 IO 线程睡 60 秒再试。主库 2 秒活过来，也要等这个周期。

## 这次实验没有证明的事

**没有丢数据 ≠ 零丢失。** 本次 kill 时主库上没有未提交事务，所以看不出问题。要真的验证"强杀会不会丢已提交事务"，得这么做：

1. 主库开一个事务，`COMMIT` 后立刻 kill（用 `--init-command` 或脚本卡时序）
2. 重连后比对主库 `@@gtid_executed` 与从库 `Retrieved_Gtid_Set`
3. 打开半同步（`rpl_semi_sync_source_enabled`）再重复一次，看差异

这是实验 03 的内容。

## 防复发

- **监控（最重要的一条）**：告警不能只看 `Seconds_Behind_Source > 阈值`。复制断了这个值是 `NULL`，任何 `> 60` 的判断都会漏掉。必须单独监控：
  - `Replica_IO_Running != Yes` → 立即报警（P1）
  - `Replica_SQL_Running != Yes` → 立即报警（P1）
  - `Seconds_Behind_Source IS NULL` → 视为复制中断
  - mysqld_exporter 里对应 `mysql_slave_status_slave_io_running` / `..._seconds_behind_master`，后者为 NaN 时别被 `avg()` 抹平
- **参数**：`SOURCE_CONNECT_RETRY` 可以调小（如 10 秒）换更快的自愈，但代价是主库真挂时重试风暴更密。多数场景保持 60 秒 + 好监控，比调参数更划算。
- **流程**：主库重启/切换后，必须显式确认三件事——从库 IO 线程状态、GTID 是否追平、有没有 `Last_IO_Error`。别等业务反馈"数据不对"。

## 自己再答一遍（不看上面）

1. 从库发现主库没了，用了多久？靠什么发现的（心跳？TCP 断开？）
2. 主库 2 秒就恢复服务，为什么从库还要等将近一分钟？
3. `Seconds_Behind_Source = NULL` 和 `= 0` 分别代表什么？哪种更危险？
