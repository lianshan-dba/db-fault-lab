# db-fault-lab

一个可以在本机复现的 MySQL / PostgreSQL 故障实验室。**一条命令起一个故障，不用装 MySQL，不会动你的硬盘。**

## 为什么有这个

DBA 的能力不是"知道怎么处理故障"，是"在故障里能按顺序想事情"。而这件事在真实环境里练不到——你不可能为了练习去把生产库 kill 掉，外包环境里也轮不到你处理核心故障。

所以自己造：容器里起实例，脚本把故障注入进去，观察现象、记录排查路径。每一次实验的产出是一篇复盘，不是一堆截图。

## 30 秒上手

**一份 compose 定义所有实验的服务，用 `profiles` 按编号分组**；每个实验只有一个注入脚本。
起哪个实验就 `--profile` 哪个，不会连带别的，镜像全机器只拉一次（所有服务引用同一个 `mysql:8.0`）。

```bash
git clone https://github.com/lianshan-dba/db-fault-lab.git
cd db-fault-lab
./lab.sh up          # 第一次：备镜像（约 1 分钟）；之后每次都直接跳过
./lab.sh use 05      # 起 05 自己的容器 + 注入磁盘写满（首次约 30 秒）
```

机器上没有 `git`（不少服务器是这样）就直接下压缩包，内容一样：

```bash
curl -Lo lab.tar.gz https://github.com/lianshan-dba/db-fault-lab/archive/refs/heads/main.tar.gz
tar xzf lab.tar.gz && cd db-fault-lab-main && ./lab.sh up && ./lab.sh use 05
```

切到 05 之后你会看到一个真实的两难现场：盘满了、业务写不进去、`df` 100%，而 `du` 只统计到一半。

```
tmpfs           768M  766M  2.1M 100% /var/lib/mysql     ← 文件系统视角
766M    /var/lib/mysql                                    ← 目录视角，两个数对不上

affected_rows
1                                                         ← 单行能插，骗人的
ERROR 1114 (HY000): The table 't_big' is full              ← 批量插入要扩页，失败
ERROR 3675 (HY000): Create table/tablespace 't_new' failed, as disk is full
```

**镜像只拉一次**（`mysql:8.0`，约 600MB），存在本地反复用；每个实验的 datadir 也只初始化一次，`use` / `reset` 都不碰它。默认从作者的阿里云公共镜像拉，国内实测 13 秒，且是多架构（Apple Silicon 原生 arm64）；拉不动会自动回退 Docker Hub 和公共加速站，细节见下面「国内网络」。

## 前置条件（就三条）

| 条件 | 说明 |
|---|---|
| docker + compose **v2** | `docker compose version` 能出版本号。v1 的 `docker-compose` 语法不兼容 |
| 内存 ≥ 4G | 三套环境全开约 2G。只跑 05 的话 1G 就够 |
| 不需要 | root、`--privileged`、loop 设备、本机装 MySQL |

macOS 没装 Docker 的话：`brew install --cask docker`，或者更轻的 `brew install colima docker && colima start --memory 4`。

先自检一遍，它会告诉你缺什么：

```bash
./lab.sh doctor
```

## 连接信息（怎么登进去）

所有实例账号密码都一样，只有端口不同。**按实验分表，一眼能看出哪个容器属于哪个实验：**

| 实验 | 服务 | 容器名 | 宿主端口 | 用户 | 密码 | 库 |
|---|---|---|---|---|---|---|
| 01 | mysql-master | `dfl-01-master` | 13306 | root | rootpass | demo |
| 01 | mysql-slave-1 | `dfl-01-slave-1` | 13307 | root | rootpass | 随主库复制 |
| 01 | mysql-slave-2 | `dfl-01-slave-2` | 13308 | root | rootpass | 随主库复制 |
| 02 | mysql-mdl | `dfl-02-mdl` | 13310 | root | rootpass | demo |
| 05 | mysql-disk-full | `dfl-05-disk-full` | 13309 | root | rootpass | demo |

复制账号是 `repl` / `replpass`，只给从库连主库用，不是给你登的。

三种连法，挑一种：

```bash
# ① 容器内的客户端 —— 本机没装 mysql 也能用，最省事
docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo

# ② 宿主机上的客户端 —— 需要装了 mysql-client
mysql -h127.0.0.1 -P13309 -uroot -prootpass demo

# ③ GUI（Navicat / DBeaver / DataGrip / TablePlus）
#    主机 127.0.0.1   端口 13309   用户 root   密码 rootpass   库 demo
```

忘了端口就跑 `./lab.sh conn`，它只列当前在跑的实例。

三个容易犯的错：

- **`@@port` 显示 3306 是正常的。** 容器内就是 3306，映射到宿主的 13309。写连接串要用宿主端口。
- **`docker exec -i` 会吃掉你的 stdin。** 在脚本里连着写几条 `docker exec -i`，后面的会像被截断一样没输出 —— 加 `</dev/null`，或者改用 `docker compose exec -T`。
- **只绑了 `127.0.0.1`。** 别的机器连不进来是有意的：这些实例没有任何防护，别往公网放。

## 命令一览

| 命令 | 做什么 | 大概多久 |
|---|---|---|
| `./lab.sh list` | 有哪些实验（编号 / 目录 / 标题） | 1 秒 |
| `./lab.sh doctor` | 查 docker / compose / 端口 / 镜像 / 内存 | 2 秒 |
| `./lab.sh up` | 只备镜像（全机器一次） | 首次 1 分钟，之后跳过 |
| `./lab.sh up 05` | 只把 05 的容器起起来，不注入 | 首次 30 秒 |
| `./lab.sh use 05` | 起 05 的容器 + 注入磁盘写满 | 首次 30 秒，之后 10 秒 |
| `./lab.sh use 05 fix` | 自己试过之后再看处置动作，对答案 | 3 秒 |
| `./lab.sh use 01` | 起一主两从 + 建复制 + kill -9 主库 | 首次 2 分钟，之后 20 秒 |
| `./lab.sh use 02` | 起单实例 + 注入元数据锁阻塞 | 首次 40 秒，之后 6 秒 |
| `./lab.sh reset 05` | 原地复原（不重建容器，`reset all` 全复原） | 1～4 秒 |
| `./lab.sh status` | 哪些实验在跑、各自什么状态 | 1 秒 |
| `./lab.sh conn` | 打印连接信息（账号、密码、端口、登录命令） | 1 秒 |
| `./lab.sh down [05]` | 停容器、留数据，下次起得快（不给编号 = 全部） | 2 秒 |
| `./lab.sh clean [05]` | 删掉容器与数据卷（镜像还留着，不会重拉） | 5 秒 |

`./lab.sh 05` 这种老写法仍然能用，等价于 `./lab.sh use 05`。

## 一次练习怎么用（这才是重点）

脚本负责造现场，**不负责替你思考**。正确的顺序是五步：

1. **先写预测。** 在 `./lab.sh use 05` 跑完、还没动手之前，写下"我 `rm` 掉慢日志之后 `df` 会降吗、为什么"。
2. **跑注入。** `./lab.sh use 05`，看现场，别急着翻 `docs/05`。
3. **自己动手取证。** 进容器看谁还开着那个被删掉的文件：
   ```bash
   docker exec -it -u mysql dfl-05-disk-full bash
   ls -l /proc/1/fd | grep deleted
   ```
   注意 `-u mysql`：容器默认给你 root，读 mysqld 的 `/proc/1/fd` 会 `Permission denied`，
   而"读不到"和"确实没有"在输出上一模一样 —— 这一步本身就值得栽一次。
4. **对答案。** `./lab.sh use 05 fix`。它演示的是**一种**处置路径，不是标准答案。
5. **复原重练。** `./lab.sh reset 05 && ./lab.sh use 05`，第二次要求自己不看笔记走完。
   复原是**原地**做的（关慢日志 → 删两个大文件 → 参数改回），不重建容器，所以一两秒就回到干净状态。

想留着现场慢慢看，就别 `reset`。真正会丢数据的是 `clean` 和 `down`：05 的 datadir 是 tmpfs，容器一停就没了 —— 这是特性，不是 bug。01、02 用的是 named volume，停了数据还在。

## 国内网络：镜像怎么拉

镜像默认从**作者的阿里云公共镜像**拉，不用配任何东西：

```
registry.cn-hangzhou.aliyuncs.com/lianshan-dba/mysql:8.0
```

匿名可拉，国内实测 13 秒（600MB）。它是**多架构索引**（`linux/amd64` + `linux/arm64`），
所以 Apple Silicon 的 Mac 拉到的是原生 arm64，不走模拟。digest 与 Docker Hub 官方索引完全一致
（`sha256:7dcddc01…`），不是重新构建的野镜像。

它不是唯一来源，`./lab.sh` 的顺序是：

```
你的指定仓库 → 上面的公共镜像 → Docker Hub → daocloud → 1panel → dockerproxy
```

任何一环失败都会自动往下走，**不会因为某一个镜像源挂了就跑不起来**。

想换成自己的仓库（公司 harbor、自己的 ACR）：

```bash
# 推上去（一次）
./tools/push-mirror.sh registry.cn-hangzhou.aliyuncs.com/你的命名空间

# 用起来
IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up

# 或者干脆跳过所有镜像源，直接走 Docker Hub
IMAGE_MIRROR=none ./lab.sh up
```

**推的时候别用 `docker push`。** 它只能推本机那一个架构（x86 机器上就是 amd64），
Apple Silicon 用户拉到会走 QEMU 模拟，MySQL 起得极慢还可能报错。`push-mirror.sh` 默认走
`buildx imagetools create`，把源仓库的**整个多架构索引**复制过去，digest 与官方一致，可以直接核对：

```bash
docker buildx imagetools inspect registry.cn-hangzhou.aliyuncs.com/你的命名空间/mysql:8.0
```

用阿里云 ACR 个人版要注意三点（`tools/push-mirror.sh` 结尾也会提醒）：

- 仓库必须设成**公开**，否则别人匿名拉会 401
- `docker login` 用的是**仓库密码**，不是阿里云账号密码
- 个人版有存储和流量额度，被大量拉取可能产生费用；作者随时可能撤掉这个公共镜像，撤了也不影响使用（会自动回退）

全都拉不动时的兜底：

```bash
# 1) 永久配加速器：Docker Desktop → Settings → Docker Engine，json 里加
"registry-mirrors": ["https://docker.m.daocloud.io"]

# 2) 借一台有网的机器把镜像搬过来（600MB，U 盘也行）
docker save mysql:8.0 | gzip > mysql80.tar.gz     # 有网的机器
docker load < mysql80.tar.gz                       # 你的机器

# 3) 指定别的加速站
MIRRORS=docker.你的源.com ./lab.sh up
```

镜像版本可以换，`MYSQL_IMAGE=mysql:8.4 ./lab.sh use 05`。实测 8.0.46 与 8.4.11 在这个故障上的行为完全一致（见 `docs/05`）。

## 端口

默认落在 `133xx`，避开你本机可能已经占着的 3306/3307/3308：

| 实验 | 服务 | 宿主端口 | 覆盖方式 |
|---|---|---|---|
| 01 | mysql-master | 13306 | `MASTER_PORT=23306 ./lab.sh use 01` |
| 01 | mysql-slave-1 | 13307 | `SLAVE1_PORT=...` |
| 01 | mysql-slave-2 | 13308 | `SLAVE2_PORT=...` |
| 02 | mysql-mdl | 13310 | `MDL_PORT=...` |
| 05 | mysql-disk-full | 13309 | `DISK_FULL_PORT=...` |

容器之间走 compose 网络别名（`mysql-master:3306`），所以改宿主端口不影响复制关系，也不影响脚本。

## 出问题了看这里

| 现象 | 原因 | 怎么办 |
|---|---|---|
| `failed to bind host port ... address already in use` | 端口被别的进程占了 | 按上表换端口 |
| `docker: command not found` / `Cannot connect to the Docker daemon` | 没装 / 没启动 | 装 Docker Desktop，或 `colima start` |
| `docker compose` 报 `unknown flag` 之类 | 用的是 compose v1 | 升级到 v2（`docker compose` 带空格） |
| `dfl-05-disk-full` 一直 `unhealthy` | 初始化失败 | `docker compose --profile 05 logs --tail=40`（在仓库根） |
| 容器里 `kill -9 1` 完全无效 | 正常：内核丢弃同一 PID namespace 内发给 1 号进程的 SIGKILL | 从宿主 `kill -9 $(docker inspect -f '{{.State.Pid}}' dfl-01-master)`，`01` 的脚本就是这么做的 |
| `ls /proc/1/fd` 空 / `Permission denied` | `exec` 默认是 root | 加 `-u mysql` |
| 磁盘满会不会把我机器写满 | 不会 | 05 的 datadir 是 768M tmpfs，占用全在容器内存里 |
| 上一个实验的影响还在（表没了 / 会话卡着 / 盘还满） | 现场是故意留着的 | `./lab.sh reset 05`（或 `reset all`），原地复原不重建容器 |
| 想同时做两个实验 | 可以，它们没有共享容器 | 直接 `./lab.sh use 01` 和 `./lab.sh use 05`，各自的 project 是 `dfl-01` / `dfl-05` |
| `docker image prune -a` 之后又要重新拉镜像 | 镜像被删了 | 再跑一次 `./lab.sh up`，只拉这一次；平时别对 lab 用 `prune -a` |

## 仓库结构

**容器定义只有一份（`compose.yml`），实验脚本各占一个目录。**
两件事分开：`compose.yml` 说「有哪些容器」，`labs/<编号>/` 说「这个故障怎么造、怎么复原」。

```
compose.yml               唯一的 compose：所有实验的服务都在这里，用 profiles 按编号分组
                          --profile 05 up -d 只起 05 的服务；不带 --profile 一个都不起
conf/                     各实例的 cnf 与初始化 SQL（master / slave / slave-2 / mdl / disk-full）
scripts/init-replica.sh   建复制关系（01 用）
lab.sh                    唯一入口：list / up / use NN / reset NN / status / conn / down / clean
lib/
  common.sh               日志、docker 检查、备镜像、等健康、打印连接信息（与实验无关）
  meta.sh                 读 labs/*/meta，把编号解析成 profile 和脚本目录（实验登记处）
labs/
  01-kill-master/         只放脚本，不含任何容器定义
    meta                  编号 / profile / 标题 / 端口 / 容器名 / 连接信息
    inject.sh  reset.sh  status.sh
  02-mdl-block/
    meta  inject.sh  reset.sh  dirty.sh
  05-disk-full/
    meta  inject.sh  fix.sh  reset.sh  dirty.sh  status.sh
tools/push-mirror.sh      把镜像推到你自己的国内仓库，加速别人拉取
docs/                     复盘，一篇一个实验
postgres/                 预留，尚未开始
```

三个约定：

- **镜像只有一个。** 所有服务都写 `image: mysql:8.0`，拉一次全部复用；`lab.sh` 起实验前先看本地，命中就打印「已就绪（不会重复拉）」。所以做到第 5 个实验也不会多下一次 600MB。
- **实验之间靠 profiles 隔离，不靠分文件。** `--profile 05 up -d` 只起 05，01 的三个容器一动不动；`--profile "*" down -v` 才是全清。三套环境可以同时开着。
- **注入脚本是分开的，一个实验一个。** 换实验只换脚本，永远不碰 `compose.yml`——除非这个实验需要新的容器。

## 实验清单

| # | 故障 | 怎么触发 | 真正要练的是 |
|---|---|---|---|
| 01 | 主库被 kill -9 | `./lab.sh use 01` | 从库 IO/SQL 线程报错怎么读，什么时候能自愈 |
| 02 | 元数据锁阻塞 | `./lab.sh use 02` | 怎么从 `performance_schema.metadata_locks` 找到源头会话 |
| 03 | 半同步退化成异步 | 待补 | 主库写入为什么突然变慢，怎么确认 |
| 04 | 从库延迟 | 待补 | 区分"真延迟"和"`Seconds_Behind_Source` 撒谎" |
| 05 | 磁盘写满 + 慢日志句柄未释放 | `./lab.sh use 05` | 删了日志 `df` 不降，不重启怎么把空间放回来 |
| 06 | binlog 被清理导致从库断流 | 待补 | `1236` 错误的三种成因和各自的修法 |
| 07 | 连接数打满 | 待补 | 从 `too many connections` 到能登录的过程 |

已完成的复盘：[01 · 主库被 kill](docs/01-kill-master.md) · [05 · 磁盘写满 + 慢日志句柄未释放](docs/05-disk-full.md)

不想跑、只想看结论的，直接读这两篇——每篇都是「问题现象 → 思考方向 → 解决方法」，现象段里的命令可以直接粘进终端复现。

## 自己加一个实验（06、07 就是这么来的）

**不用改 `lab.sh`。** 两步：compose 里加一段服务，`labs/` 下建一个目录放脚本。

### 第一步：compose.yml 里加服务（只有需要新容器时才做）

复制一段现有的，改 `profiles`、`container_name`、端口：

```yaml
  mysql-binlog:
    profiles: ["06"]                    # 编号即 profile，lab.sh 就靠这个起
    image: mysql:8.0                    # 还是那个镜像，不会重新拉
    container_name: dfl-06-binlog
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: demo
    ports:
      - "127.0.0.1:${BINLOG_PORT:-13311}:3306"
    volumes:
      - ./conf/binlog.cnf:/etc/mysql/conf.d/zz-lab.cnf:ro
      - binlog-data:/var/lib/mysql
    healthcheck: ...                    # 照抄别的服务
```

再往文件末尾的 `volumes:` 里加 `binlog-data:`。

### 第二步：建脚本目录

```bash
mkdir -p labs/06-binlog-purged
```

| 文件 | 必须 | 作用 |
|---|---|---|
| `meta` | 是 | 编号、profile、标题、端口、容器名、连接信息。`lab.sh list` 和 `use` 全从这读 |
| `inject.sh` | 是 | 注入故障，打印现场，最后列出「接下来你自己回答的问题」 |
| `reset.sh` | 是 | **原地**把注入留下的东西抹掉（表、会话、文件、参数），不删容器、不重建 datadir |
| `fix.sh` | 否 | 处置演示，`use 06 fix` 会调它 |
| `dirty.sh` | 否 | 返回 0 表示"现场还在"，`use` 前会自动先 `reset` |
| `status.sh` | 否 | 额外状态（df、复制状态…），`./lab.sh status` 会调它 |

`meta` 就是几行 KEY=VALUE：

```
NB=06
PROFILE=06                     # compose 里的 profiles 名，一般等于编号
NAME=binlog-purged
TITLE=binlog 被清理导致从库断流
DESC=PURGE BINARY LOGS 之后从库报 1236（独立实例）
PORTS="BINLOG_PORT:13311"
CONTAINERS="dfl-06-binlog"
CONN="独立实例 mysql-binlog|mysql-binlog|BINLOG_PORT|dfl-06-binlog"
```

脚本统一从仓库根出发，用那一份 compose：

```bash
cd "$(dirname "$0")/../.."
COMPOSE="docker compose"
$COMPOSE exec -T mysql-binlog mysql -uroot -prootpass demo -e "..."
```

判断标准有两条：**别人 clone 下来能不能一条命令跑出来**，**跑完能不能两秒内复原再跑一遍**。

复原脚本是这个仓库最容易被忽略的部分：写注入五分钟就想完事，写复原要真正搞清楚「这个故障在环境里留下了什么」。后者恰恰是故障处置的真本事。

## 每篇复盘的格式

固定三段，写不出第二段说明这个实验白做了：

```
## 一、问题现象      ——  能直接粘进终端的命令 + 它真实的输出/报错号，原文照抄
## 二、思考方向      ——  为什么会这样：判断顺序、排除掉的错路、机制
## 三、解决方法      ——  处置步骤（同样带命令）+ 怎么验证好了 + 防复发
```

两篇复盘（`docs/01`、`docs/05`）就是照这个写的，可以直接当模板。

**「问题现象」这一段的硬标准：** 每条现象必须是「命令 + 屏幕上的原文」，像这样 ——

```bash
$ docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo \
    -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB"
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

写"建表会失败"不算；写"报 ERROR 3675 ... disk is full"、并且给出发这条命令的方法，别人才能照着复现。

## 注意

- 这套东西只在本机跑，**不要**接到任何真实环境。
- 提交前扫一遍：内网 IP、主机名、公司名、账号密码。示例里统一用 `10.0.0.x` 和 `db-prod-01` 这类假值。
- 所有密码都是 `rootpass` / `replpass`，只给本地实验用，不要复用到任何真实环境（清单见上面「连接信息」）。
