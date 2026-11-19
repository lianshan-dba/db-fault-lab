# db-fault-lab

一个可以在本机复现的 MySQL / PostgreSQL 故障实验室。

## 为什么有这个

DBA 的能力不是"知道怎么处理故障"，是"在故障里能按顺序想事情"。而这件事在真实环境里练不到——你不可能为了练习去把生产库 kill 掉，外包环境里也轮不到你处理核心故障。

所以自己造：`docker compose up` 起一套一主两从，然后用脚本把故障注入进去，观察现象、记录排查路径。每一次实验的产出是一篇复盘，不是一堆截图。

## 快速开始

```bash
cd mysql
docker compose up -d
./scripts/init-replica.sh        # 建好复制关系
docker compose ps                # 三个都 healthy 再继续
```

连上主库：

```bash
docker compose exec mysql-master mysql -uroot -prootpass demo
```

## 实验清单

| # | 故障 | 怎么触发 | 真正要练的是 |
|---|---|---|---|
| 01 | 主库被 kill -9 | `inject/kill-master.sh` | 从库 IO/SQL 线程报错怎么读，什么时候能自愈 |
| 02 | 元数据锁阻塞 | `inject/mdl-block.sh` | 怎么从 `performance_schema.metadata_locks` 找到源头会话 |
| 03 | 半同步退化成异步 | 停掉两个从库再压测 | 主库写入为什么突然变慢，怎么确认 |
| 04 | 从库延迟 | 主库跑大事务 / 无主键表批量更新 | 区分"真延迟"和"`Seconds_Behind_Master` 撒谎" |
| 05 | 磁盘写满 + 慢日志句柄未释放 | `inject/disk-full.sh` | 删了日志 `df` 不降，不重启怎么把空间放回来 |
| 06 | binlog 被清理导致从库断流 | `PURGE BINARY LOGS` | `1236` 错误的三种成因和各自的修法 |
| 07 | 连接数打满 | 脚本开 200 个空闲连接 | 从 `too many connections` 到能登录的过程 |

（03 之后陆续补，每做完一个补一篇 `docs/`）

**05 用的是独立实例** `mysql-disk-full`（3309，datadir 挂在一块 768M 的 tmpfs 上），不跟主从共用 ——
造 `ENOSPC` 不能填满你自己的硬盘。它不在默认启动范围里，要单独起：

```bash
docker compose up -d mysql-disk-full
```

不要写成 `--profile disk-full up -d`，那会把一主两从一起拉起来，而它们的 3306 通常已被本机 MySQL 占着。

## 每篇复盘的格式

固定五段，写不出第五段说明这个实验白做了：

```
## 现象（贴原始报错，不要转述）
## 时间线（精确到分钟）
## 排查过程（包括走错的路）
## 根因
## 防复发（改了什么监控 / 参数 / 流程）
```

## 注意

- 这套东西只在本机跑，**不要**接到任何真实环境。
- 如果本机 3306 已经被 MySQL 占着（DBA 的机器基本都是），`docker compose up -d` 会在 bind 端口时失败。
  改 compose 里的映射端口，或者只起需要的那几个服务。
- 提交前扫一遍：内网 IP、主机名、公司名、账号密码。示例里统一用 `10.0.0.x` 和 `db-prod-01` 这类假值。
- 所有密码都是 `rootpass` / `replpass`，仅用于本地实验，不要复用。
