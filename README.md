# db-fault-lab

一条命令在本机复现一个 MySQL 故障现场。**不用装 MySQL，不用 root，也不会把你的盘写满。**

DBA 的能力不是"知道怎么处理故障"，是"在故障里能按顺序想事情"，而这件事在真实环境里练不到。所以这里把故障造出来：容器里起实例，脚本注入故障，你负责观察和判断。

## 实验清单

每个实验一个编号，`use 编号` 就切过去。**点编号进 `docs/`，看这个故障怎么构造、命令和真实报错原文。**

| # | 故障 | 一条命令 | 端口 | 复盘 |
|---|---|---|---|---|
| 01 | 主库被 kill -9 | `./lab.sh use 01` | 13306-13308 | [docs/01](docs/01-kill-master.md) |
| 02 | 元数据锁阻塞 | `./lab.sh use 02` | 13310 | [labs/02](labs/02-mdl-block/)（复盘待写） |
| 05 | 磁盘写满 + 慢日志句柄未释放 | `./lab.sh use 05` | 13309 | [docs/05](docs/05-disk-full.md) |
| 03 04 06 07 | 半同步退化 / 从库延迟 / binlog 断流 / 连接数打满 | 待补 | — | — |

**下面用 05 走一遍**，其他实验是同一套动作，只是编号和现象不同。

## 快速开始

只需要 docker + compose v2、4G 内存（只跑 05 的话 1G 够）。不用 root、不用 `--privileged`、不用 loop 设备。

```bash
git clone https://github.com/lianshan-dba/db-fault-lab.git
cd db-fault-lab
./lab.sh doctor      # 自检：缺什么它会说
./lab.sh up          # 第一次：备镜像（约 1 分钟）；之后每次都直接跳过
./lab.sh use 05      # 起 05 的容器 + 注入故障（首次约 30 秒）
```

机器上没有 `git`（不少服务器是这样）就用压缩包，内容一样：

```bash
curl -Lo lab.tar.gz https://github.com/lianshan-dba/db-fault-lab/archive/refs/heads/main.tar.gz
tar xzf lab.tar.gz && cd db-fault-lab-main && ./lab.sh up && ./lab.sh use 05
```

## 以 05 为例：从零到现场，再到处置

### 第 1 步：起环境

```bash
$ ./lab.sh use 05
    镜像已就绪：mysql:8.0（不会重复拉）

==> 起 05 disk-full 的环境（docker compose up -d，首次要初始化）
 Container dfl-05-disk-full  Started
==> 注入：05 磁盘写满 + 慢日志句柄未释放
```

镜像全机器只拉一次（约 600MB），datadir 也只初始化这一次。后面 `reset` 不重建容器，所以复练是秒级的。

### 第 2 步：看现场

```bash
========== 现在的现场 ==========
--- df：文件系统视角
tmpfs           768M  766M  2.1M 100% /var/lib/mysql
--- du：目录视角
    766M	/var/lib/mysql
--- 业务写入的三种表现（注意差别，第 1 条会骗人）
[1] 单行 INSERT（看 affected_rows）
affected_rows
1
[2] 批量 INSERT 5000 行（要扩 .ibd）
ERROR 1114 (HY000) at line 1: The table 't_big' is full
[3] CREATE TABLE
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

盘满了、建表报错，**可单行 INSERT 居然成功** —— 这就是要练的地方：能不能插一条永远不能用来判断盘满。脚本接着会把每条可粘的命令和对应报错打出来，直接照着敲。

### 第 3 步：自己动手，先写预测

删掉那个 363M 的慢日志，`df` 会降吗？想清楚再敲：

```bash
$ docker exec -it dfl-05-disk-full rm -f /var/lib/mysql/slow.log
$ docker exec -it dfl-05-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
tmpfs           768M  768M     0 100% /var/lib/mysql     ← 完全没降（比刚才多的 2M 是那几条 INSERT 写的）
406M	/var/lib/mysql                                  ← 掉了约 360M
```

两个数分叉了，说明有进程还开着那个已被删除的文件。取证要加 `-u mysql`（容器默认给 root，读不到 mysqld 的 fd）：

```bash
$ docker exec -u mysql -it dfl-05-disk-full ls -l /proc/1/fd | grep 'slow\.log'
l-wx------. 1 mysql mysql 64 Nov 20 00:32 36 -> /var/lib/mysql/slow.log (deleted)
```

### 第 4 步：对答案

```bash
$ ./lab.sh use 05 fix
==> 3. 不重启，只关慢日志 —— 等于让 mysqld 执行 close(fd)
tmpfs           768M  406M  363M  53% /var/lib/mysql     ← 363M 立刻回来
==> 4. 清掉人为的 filler（真实场景里对应大事务结束自己释放的临时文件）
tmpfs           768M  133M  636M  18% /var/lib/mysql
==> 7. 实例重启过没有
    Uptime: 19s → 23s，单调增长，说明全程没重启。
```

它演示的是**一种**处置路径，不是标准答案。完整推理、走错的四条路、防复发，在 [docs/05](docs/05-disk-full.md)。

### 第 5 步：复原重练

```bash
./lab.sh reset 05    # 1 秒，原地复原：关慢日志 → 删大文件 → 参数改回
./lab.sh use 05      # 第二次要求不看笔记走完
```

想留着现场慢慢看就别 `reset`；真正会丢数据的是 `clean` 和 `down`（05 的 datadir 是 tmpfs，容器一停就没了，这是特性不是 bug）。

## 命令

| 命令 | 做什么 |
|---|---|
| `./lab.sh list` | 有哪些实验 |
| `./lab.sh doctor` | 查 docker / compose / 端口 / 镜像 / 内存 |
| `./lab.sh up` | 只备镜像（全机器一次）；`up 05` 只起 05 的容器不注入 |
| `./lab.sh use NN` | 起这个实验的环境 + 注入故障（首次几十秒，之后几秒） |
| `./lab.sh use 05 fix` | 处置演示，自己试过再看（不是每个实验都有） |
| `./lab.sh reset NN` | 原地复原，不重建容器；`reset all` 全复原 |
| `./lab.sh status` | 现在哪些实验在跑、各自什么状态（盘用了多少、复制通不通） |
| `./lab.sh conn` | 打印连接信息（账号、密码、端口、登录命令） |
| `./lab.sh down` / `clean` | 停容器留数据 / 删容器与数据卷（镜像都还留着） |

`./lab.sh 05` 这种老写法仍然能用，等价于 `use 05`。所有实验可以同时开着，互不干扰。

## 连进去

账号统一 `root` / `rootpass`，库 `demo`（01 的从库跟着主库复制，不用单独建库）。端口按实验分：01 是 13306-13308，05 是 13309，02 是 13310。**忘了就跑 `./lab.sh conn`，它只列当前在跑的实例。**

```bash
docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo    # 容器内客户端，没装 mysql 也能用
mysql -h127.0.0.1 -P13309 -uroot -prootpass demo                  # 宿主机客户端
# GUI：主机 127.0.0.1  端口 13309  用户 root  密码 rootpass  库 demo
```

三个容易犯的错：

- **`@@port` 显示 3306 是正常的。** 容器内就是 3306，映射到宿主的 13309。
- **`docker exec -i` 会吃掉你的 stdin。** 脚本里连写几条会让后面的像被截断，加 `</dev/null` 或改用 `docker compose exec -T`。
- **只绑了 `127.0.0.1`**，别的机器连不进来是有意的：这些实例没有防护，别往公网放。

## 镜像（国内网络）

默认从作者的阿里云公共镜像拉，不用配置：`registry.cn-hangzhou.aliyuncs.com/lianshan-dba/mysql:8.0`。匿名可拉，国内实测 13 秒，是**多架构索引**（amd64 + arm64，Apple Silicon 原生跑），digest 与 Docker Hub 官方一致。

拉取顺序是「你指定的仓库 → 上面的公共镜像 → Docker Hub → daocloud → 1panel → dockerproxy」，任何一环失败自动往下走。

```bash
IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up   # 换成自己的仓库
IMAGE_MIRROR=none ./lab.sh up                                            # 只用 Docker Hub
MYSQL_IMAGE=mysql:8.4 ./lab.sh use 05                                    # 换 MySQL 版本
```

想自己推镜像用 `./tools/push-mirror.sh`，它走 `buildx imagetools create` 复制整个多架构索引（`docker push` 只推本机那一个架构，Apple Silicon 用户拉到会走 QEMU 模拟）。

## 出问题了

| 现象 | 怎么办 |
|---|---|
| `failed to bind host port ... address already in use` | 换端口：`MASTER_PORT=23306 ./lab.sh use 01`（其他同理，变量名见 `labs/*/meta` 的 `PORTS`） |
| `docker: command not found` / `Cannot connect to the Docker daemon` | 装 Docker Desktop，macOS 也可以 `brew install colima docker && colima start --memory 4` |
| `docker compose` 报 `unknown flag` | 用的是 compose v1，升级到 v2（`docker compose` 中间是空格） |
| 容器一直 `unhealthy` | `docker compose --profile 05 logs --tail=40`（在仓库根，编号换成你的） |
| 上一个实验的影响还在（表没了 / 会话卡着 / 盘还满） | 现场是故意留着的，`./lab.sh reset 05` |
| 想同时做两个实验 | 直接 `use 01` 和 `use 05`，各自容器独立 |
| `docker image prune -a` 之后要重新拉镜像 | 再跑 `./lab.sh up`；平时别对 lab 用 `prune -a` |

## 目录结构

容器定义只有一份（`compose.yml`），实验脚本各占一个目录，两者分开：

```
compose.yml               所有实验的服务都在这里，用 profiles 按编号分组
                          --profile 05 up -d 只起 05；不带 --profile 一个都不起
conf/                     各实例的 cnf 与初始化 SQL
scripts/init-replica.sh   建复制关系（01 用）
lab.sh                    唯一入口
lib/                      common.sh（日志/镜像/健康检查）+ meta.sh（实验登记处）
labs/<编号>-<名字>/        meta + inject.sh + reset.sh（+ 可选 fix.sh / dirty.sh / status.sh）
tools/push-mirror.sh      把镜像推到你自己的国内仓库
docs/                     复盘，一篇一个实验
```

三条约定：**镜像只有一个**（所有服务都是 `mysql:8.0`，拉一次全复用）；**实验之间靠 profiles 隔离**，不靠拆文件；**注入脚本一个实验一个**，换实验只换脚本，不改 `compose.yml`。

## 加一个实验

不用改 `lab.sh`：`compose.yml` 里加一段服务（`profiles: ["06"]`、容器名 `dfl-06-xxx`、端口 13311，末尾 `volumes:` 加一行），再建 `labs/06-<名字>/` 放 `meta` + `inject.sh` + `reset.sh`。`meta` 是几行 KEY=VALUE（编号、profile、标题、端口、容器名、连接信息），照 `labs/05-disk-full/meta` 抄。

注入和复原必须成对写：`reset.sh` 要**原地**把注入留下的东西抹掉（表、会话、文件、参数），不删容器。写注入五分钟就想完事，写复原要真搞清「这个故障在环境里留下了什么」——后者才是处置的本事。

## 复盘怎么写

固定三段：**问题现象 / 思考方向 / 解决方法**。`docs/01` 和 `docs/05` 就是模板。

「现象」的硬标准是「命令 + 屏幕原文」，写"建表会失败"不算，要写成：

```bash
$ docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB"
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

## 注意

只在本机跑，**不要**接到真实环境。提交前扫一遍内网 IP、主机名、公司名、真实账号。所有密码（`rootpass` / `replpass`）只给本地实验用。
