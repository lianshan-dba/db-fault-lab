# db-fault-lab

一条命令在本机复现一个 MySQL 故障现场。**不用装 MySQL，不用 root，也不会把你的盘写满。**

DBA 的能力不是「知道怎么处理故障」，是「在故障里能按顺序想事情」，而这件事在真实环境里练不到。所以这里把故障造出来：容器里起实例，脚本注入故障，你负责观察和判断。

## 固定账号与端口

所有实验一套账号，不用记：

| 用途 | 值 |
|---|---|
| 用户 / 密码 | `root` / `rootpass` |
| 实验库 | `demo` |
| 复制账号 | `repl` / `replpass` |
| 端口 | 01 主 13306、从 13307/13308 ｜ 05 13309 ｜ 02 13310 ｜ 06 主 13311、从 13312 |

只用 `127.0.0.1`，别的机器连不进来（这些实例没有任何防护）。记不住就跑 `./lab.sh conn`，它只列当前在跑的实例。

## 实验清单

`use 编号` 切过去。**点编号进 docs/，看这个故障怎么构造、命令和真实报错原文。**

| # | 故障 | 一条命令 | 端口 | 复盘 |
|---|---|---|---|---|
| 01 | 主库被 kill -9 | `./lab.sh use 01` | 13306-13308 | [docs/01](docs/01-kill-master.md) |
| 02 | 元数据锁阻塞 | `./lab.sh use 02` | 13310 | [labs/02](labs/02-mdl-block/)（复盘待写） |
| 05 | 磁盘写满 + 慢日志句柄未释放 | `./lab.sh use 05` | 13309 | [docs/05](docs/05-disk-full.md) |
| 06 | binlog 被清理，从库断流 | `./lab.sh use 06` | 13311 / 13312 | [docs/06](docs/06-binlog-purged.md) |
| 03 04 07 | 半同步退化 / 从库延迟 / 连接数打满 | 待补 | — | — |

**下面用 05 走一遍**，其他实验是同一套动作，只是编号和现象不同。

## 快速开始

前置：docker + compose v2；只跑 05 要 1G 内存，跑 01 要 4G。不用 root、不用 `--privileged`、不用 loop 设备。

```bash
git clone https://github.com/lianshan-dba/db-fault-lab.git
cd db-fault-lab
./lab.sh doctor      # 自检，缺什么它会说
./lab.sh up          # 第一次：备镜像（约 1 分钟）；之后每次直接跳过
./lab.sh use 05      # 起 05 的容器 + 注入故障（首次约 30 秒）
```

机器上没有 `git` 就下压缩包（内容一样）：
`curl -Lo lab.tgz https://github.com/lianshan-dba/db-fault-lab/archive/refs/heads/main.tar.gz && tar xzf lab.tgz && cd db-fault-lab-main`

## 以 05 为例：从零到现场，再到处置

### 第 1 步：起环境

```bash
$ ./lab.sh use 05
    镜像已就绪：mysql:8.0（不会重复拉）
==> 起 05 disk-full 的环境（docker compose up -d，首次要初始化）
 Container dfl-05-disk-full  Started
==> 注入：05 磁盘写满 + 慢日志句柄未释放
```

镜像全机器只拉一次（约 600MB），datadir 也只初始化这一次。后面 `reset` 不重建容器，复练是秒级的。

### 第 2 步：看现场

```bash
tmpfs           768M  766M  2.1M 100% /var/lib/mysql
    766M	/var/lib/mysql
[1] 单行 INSERT（看 affected_rows）
affected_rows
1
[2] 批量 INSERT 5000 行（要扩 .ibd）
ERROR 1114 (HY000) at line 1: The table 't_big' is full
[3] CREATE TABLE
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

盘满了、建表报错，**单行 INSERT 却成功了** —— 这就是要练的地方：插一条成功永远不能用来判断盘满。脚本接着会把每条可粘的命令和对应报错打出来，照着敲就行。

### 第 3 步：自己动手，先写预测

删掉那个 363M 的慢日志，`df` 会降吗？想清楚再敲：

```bash
$ docker exec -it dfl-05-disk-full rm -f /var/lib/mysql/slow.log
$ docker exec -it dfl-05-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
tmpfs           768M  768M     0 100% /var/lib/mysql     ← 完全没降（多的 2M 是刚才那几条 INSERT）
406M	/var/lib/mysql                                  ← 掉了约 360M
```

两个数分叉，说明有进程还开着那个已删除的文件。取证要加 `-u mysql`（容器默认给 root，读不到 mysqld 的 fd）：

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

它演示的是**一种**处置路径，不是标准答案。完整推理、走错的四条路、防复发在 [docs/05](docs/05-disk-full.md)。

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
| `./lab.sh up` | 只备镜像（全机器一次）；`up 06` 只起 06 的容器不注入 |
| `./lab.sh use NN` | 起这个实验的环境 + 注入故障（首次几十秒，之后几秒） |
| `./lab.sh use NN fix` | 处置演示，自己试过再看（05、06 有） |
| `./lab.sh reset NN` | 原地复原，不重建容器；`reset all` 全复原 |
| `./lab.sh status` | 哪些实验在跑、各自什么状态（盘用了多少、复制通不通） |
| `./lab.sh conn` | 连接信息（账号、密码、端口、登录命令） |
| `./lab.sh down` / `clean` | 停容器留数据 / 删容器与数据卷（镜像都还留着） |

`./lab.sh 05` 这种老写法等价于 `use 05`。所有实验可以同时开着，互不干扰。

## 连进去

```bash
docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo    # 容器内客户端，没装 mysql 也能用
mysql -h127.0.0.1 -P13309 -uroot -prootpass demo                  # 宿主机客户端
# GUI：主机 127.0.0.1  端口 13309  用户 root  密码 rootpass  库 demo
```

三个容易犯的错：

- **`@@port` 显示 3306 是正常的。** 容器内就是 3306，映射到宿主的 13309。
- **`docker exec -i` 会吃掉 stdin。** 脚本里连写几条会让后面的像被截断，加 `</dev/null` 或改用 `docker compose exec -T`。
- **只绑了 `127.0.0.1`**，别的机器连不进来是有意的。

## 镜像（国内网络）

默认从作者的阿里云公共镜像拉，不用配置：`registry.cn-hangzhou.aliyuncs.com/lianshan-dba/mysql:8.0`。匿名可拉，国内实测 13 秒，多架构（amd64 + arm64），digest 与 Docker Hub 官方一致。拉取顺序「你指定的仓库 → 公共镜像 → Docker Hub → daocloud → 1panel → dockerproxy」，任何一环失败自动往下走。

```bash
IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up   # 换自己的仓库
IMAGE_MIRROR=none ./lab.sh up                                            # 只用 Docker Hub
MYSQL_IMAGE=mysql:8.4 ./lab.sh use 05                                    # 换 MySQL 版本
```

自己推镜像用 `./tools/push-mirror.sh`，它走 `buildx imagetools create` 复制整个多架构索引（`docker push` 只推本机架构，Apple Silicon 用户拉到会走 QEMU 模拟）。

## 出问题了

| 现象 | 怎么办 |
|---|---|
| `address already in use` | 换端口：`MASTER_PORT=23306 ./lab.sh use 01`（变量名见 `labs/*/meta` 的 `PORTS`） |
| `Cannot connect to the Docker daemon` | 装 Docker Desktop；macOS 也可以 `brew install colima docker && colima start --memory 4` |
| `docker compose` 报 `unknown flag` | 是 compose v1，升级到 v2（`docker compose` 中间是空格） |
| 容器一直 `unhealthy` | `docker compose --profile 05 logs --tail=40`（在仓库根，编号换成你的） |
| 上一个实验的影响还在（表没了 / 会话卡着 / 盘还满） | 现场是故意留着的，`./lab.sh reset 05` |
| `docker image prune -a` 之后要重新拉镜像 | 再跑一次 `./lab.sh up`；平时别对 lab 用 `prune -a` |

## 结构

容器定义只有一份，实验脚本各占一个目录，两件事分开：

```
compose.yml    所有实验的服务，用 profiles 按编号分组（不带 --profile 一个都不起）
conf/          各实例的 cnf 与初始化 SQL
scripts/       建复制关系（01、06 共用，参数是「主库 从库...」）
lab.sh         唯一入口；lib/ 是公共库和实验登记处
labs/<编号>/   meta + inject.sh + reset.sh（+ 可选 fix.sh / dirty.sh / status.sh）
docs/          复盘，一篇一个实验
```

三条约定：**镜像只有一个**（都是 `mysql:8.0`，拉一次全复用）；**实验靠 profiles 隔离**，不靠拆文件；**注入脚本一个实验一个**，换实验只换脚本。

## 加一个实验

不用改 `lab.sh`：`compose.yml` 里加一段服务（`profiles: ["07"]`、容器名 `dfl-07-xxx`、端口 13313，末尾 `volumes:` 加一行），再建 `labs/07-<名字>/` 放 `meta` + `inject.sh` + `reset.sh`，照 `labs/06-binlog-purged/` 抄。

注入和复原必须成对：`reset.sh` 要**原地**把注入留下的东西抹掉（表、会话、文件、参数），不删容器。写注入五分钟就想完事，写复原才要真搞清「这个故障在环境里留下了什么」——后者才是处置的本事。

## 复盘怎么写

固定三段：**问题现象 / 思考方向 / 解决方法**。`docs/05`、`docs/06` 就是模板。

「现象」的硬标准是「命令 + 屏幕原文」，写「建表会失败」不算，要写成：

```bash
$ docker exec -it dfl-05-disk-full mysql -uroot -prootpass demo -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB"
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

## 注意

只在本机跑，**不要**接到真实环境。提交前扫一遍内网 IP、主机名、公司名、真实账号。密码（`rootpass` / `replpass`）只给本地实验用。
