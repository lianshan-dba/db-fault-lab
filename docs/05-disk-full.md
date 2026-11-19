---
title: 05 · 磁盘写满 + 慢日志句柄未释放
date: 2026-11-19
status: 已复现（容器 mysql:8.0.46 一条命令可复现；另有 8.4.11 真机对照）
---

> 原来这个实验只写了「报错顺序：先写不进去的是 binlog 还是 redo」。
> 那一半查版本行为就能答，练不出东西。
>
> 真正值钱的是后半段：**日志已经删了，`df` 为什么不降；以及不重启怎么把空间放回来。**
> 这一半不看文档记不住，只有亲手做一遍才会形成条件反射。

## 复现

环境是**常驻的**：镜像只拉一次，容器只起一次，之后靠脚本切故障、原地复原，
不重建容器，也就不需要每次再等 30 秒初始化。

```bash
./lab.sh up          # 第一次：备镜像 + 起实例（约 1 分钟）；以后几秒
./lab.sh use 05      # 切到这个故障：灌慢日志 → 填满盘 → 打印现场和待答问题（2 秒）
./lab.sh use 05 fix  # 自己试过之后再跑，对答案
./lab.sh reset 05    # 原地复原：关慢日志 → 删 filler 和大日志 → 参数改回（2 秒）
```

**为什么是 reset 而不是 clean**：`clean` 会连容器和 datadir 一起删，下次又得重新初始化。
`reset` 只把注入留下的东西抹掉，容器一直活着 —— 这也是这个实验能反复练的前提。
两者都是「回到干净状态」，差别只在秒数和要不要重等初始化。

不想用入口脚本，也可以手工做：

```bash
cd mysql
docker compose up -d mysql-disk-full      # 只起这一个实例（宿主 13309）
./inject/disk-full.sh                     # 注入故障 + 打印现场
./inject/disk-full-fix.sh                 # 自己试过之后再跑，对答案
./inject/disk-full-reset.sh               # 原地复原，接着练下一轮
```

`mysql-disk-full` 是**独立实例**，datadir 挂在一块 768M 的 tmpfs 上。不跟 `mysql-master` 共用，是因为
master 的 datadir 是 named volume，容量跟着宿主磁盘走 —— 想造 `ENOSPC` 就得把你自己机器的盘填满。

要自己登进去看（照 `df` 判断盘满是不够的，得进实例里试写入）：

```bash
docker exec -it dfl-disk-full mysql -uroot -prootpass demo       # 容器内客户端
mysql -h127.0.0.1 -P13309 -uroot -prootpass demo                  # 宿主机有客户端时
```

账号 `root` / `rootpass`，库 `demo`，宿主端口 13309（`./lab.sh conn` 随时能查到）。

两个必须注意的地方：

- **别写 `--profile disk-full up -d`**。compose 会把没写 profile 的服务（一主两从）一起拉起来，白等一分钟初始化。
  只写服务名就只起那一个。
- **容器停掉数据就没了**。这是 tmpfs 的特性（`down` / `clean` 都会触发）。
  想反复练别停容器，用 `./lab.sh reset 05`：两秒回到干净状态，容器和数据目录都还在。

## 环境

同一套机制在两种环境上各跑了一遍，数字能对上：

| | 容器版（可复现） | 真机版（验证行为） |
|---|---|---|
| MySQL | 8.0.46 | 8.4.11 |
| 盘 | tmpfs 768M | loop + ext4 974M |
| 初始化后占用 | 130M | 119M |
| 结果 | 完全一致 | 完全一致 |

真机那台是 4C/15G 的测试机（Rocky Linux 10.2），**SELinux Enforcing**。如果要在真机上复刻，多两个坑：

```bash
chcon -R -t mysqld_db_t /mnt/labdisk                                    # 否则 mysqld 读不了 datadir
semanage port -a -t mysqld_port_t -p tcp 3310                           # 否则 bind 直接被拒
```

容器里没有 SELinux，所以脚本不处理这两步。**这也是我一开始想岔的地方**：我以为必须在真机上做才真实，
其实 `ENOSPC`、`df`/`du` 的分歧、`(deleted)` 句柄这三件事，在 tmpfs 和 ext4 上行为完全一样。
真机唯一多给的东西是 SELinux 和块设备，那是部署问题，不是故障机制问题。

## 现象（原始输出，照抄）

盘满之后，三种写入的表现**完全不一样**：

```
[1] 单行 INSERT（看 affected_rows）
affected_rows
1                          ← 成功了。这一条会骗人

[2] 批量 INSERT 5000 行（要扩 .ibd）
ERROR 1114 (HY000) at line 1: The table 't_big' is full

[3] CREATE TABLE
ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full
```

服务端日志：

```
[ERROR] [MY-012640] [InnoDB] Error number 28 means 'No space left on device'
[ERROR] [MY-013133] [Server] Create table/tablespace 't_new' failed, as disk is full.
[ERROR] [MY-010907] [Server] Error writing file '/var/lib/mysql/slow.log' (errno: 28 - No space left on device)
```

**第一条最容易被误读：单行能插进去，不代表盘没满。** 已有数据页还有空隙就塞得下，要扩 `.ibd` 才失败。
8.0.46 和 8.4.11 都是这个行为。

删掉慢日志之后：

> **先注意时间点。** 注入刚完成时 `df` 的 Used 和 `du` 是**相等**的（都是 768M）——
> 什么都没删，两边看到的是同一批文件。如果你看到两个数一直相等，先确认自己是不是
> **还没做 `rm` 那一步**。分叉是删了之后才出现的，这也是这个实验唯一需要你亲手做对的动作。

```bash
$ df -h /var/lib/mysql
tmpfs  768M  768M  0  100% /var/lib/mysql     # 一点没降

$ du -sh /var/lib/mysql
406M                                          # 掉了 362M

$ ls -l /proc/1/fd | grep deleted
l-wx------. 1 mysql mysql 64 Nov 19 13:46 36 -> /var/lib/mysql/slow.log (deleted)
```

> 顺带一句：`grep deleted` 平时就会输出几条 `/tmp/#68721849 (deleted)`，那是 InnoDB 的临时文件，
> 一直在、也很小，不是嫌疑对象。**认准 `slow.log`**，别看见 `deleted` 就以为自己找到了。

关掉慢日志：

```bash
$ df -h /var/lib/mysql
tmpfs  768M  406M  363M  53% /var/lib/mysql   # 362M 立刻回来
```

## 时间线

容器版是脚本化的，全程约 15 秒。下面是一次真机演练的分秒记录，路径完全一致：

| 时间 | 发生了什么 | 证据 |
|---|---|---|
| 21:18:47 | 独立实例初始化开始 | `init.err`: `MySQL Server Initialization - start` |
| 21:18:51 | 初始化结束，占用 119M | `du -sh data` |
| 21:19:00 | 实例就绪，监听 3310 | `ready for connections` |
| 21:19:1x | 灌入 780KB 长 SQL × 600 条 | 慢日志 **447M**，盘用到 64% |
| 21:19:2x | filler 补刀 378M | `df` **958M / 100%** |
| 21:19:27 | 建表失败 | `ERROR 3675 ... disk is full` |
| 21:19:35 | 慢日志首次写失败 | `[ERROR] [MY-010907] ... errno: 28` |
| 21:19:4x | `rm slow.log` | `df` **仍 958M**，`du` 掉到 511M |
| 21:19:4x | 确认 fd 持有已删除 inode | `fd → slow.log (deleted)` |
| 21:20:0x | `SET GLOBAL slow_query_log=OFF` | `df` **511M**，447M 回来 |
| 21:20:1x | 清 filler、阈值改回 1、重开 | 新 `slow.log` 1.3K，`df` 149M |
| 21:20:2x | 业务恢复 | `INSERT ... 3554 rows affected` |

全程实例 `Uptime` 单调增长，**没有重启**。

## 排查过程（包括走错的路）

标准动作没问题：`df -h` 找满的盘 → `du` 找大目录 → 定位到 `slow.log` → 删掉。

**然后卡住的地方来了：`df` 还是 100%。** 这里有四条歧路，我走了其中三条。

**坑一：去怀疑文件系统。** 查 `mount`、`dumpe2fs`，怀疑 loop 设备有问题、挂载丢了。全错。
`df` 和块设备都正常，删除也真的生效了（`ls` 能看到文件没了）。
真正的岔路口是**同时看 `df` 和 `du`**：两个数对不上，只有一个解释 —— 有进程还开着那个被删掉的 inode。

**坑二：用单行 `INSERT` 判断盘满。** 返回 `Query OK`，一度以为磁盘已经恢复，直到批量插入报
`ERROR 1114` 才发现被骗。**判断盘满不能用"能不能插一条"，要用需要扩展的操作（建表、批量导入），或者直接看 `df`。**

**坑三：`grep -i slow` 把自己骗了。** 关掉慢日志后想确认句柄没了，`grep -i slow` 输出一整屏 fd，
看起来像"句柄还在"。实际是 grep 把**路径名** `/mnt/labdisk/` 也匹配上了。
正确写法是 `grep 'slow\.log'`，并且看有没有 `(deleted)` 后缀 —— 重开慢日志会有一个**新的** fd
指向真实文件，那是正常的。（容器里路径是 `/var/lib/mysql/`，反而不会踩这个坑，但真机一定会。）

**坑四（容器版特有）：`/proc/1/fd` 权限不足，看起来像"没有句柄"。**
mysqld 在容器里以 `mysql` 用户运行，而 `docker compose exec` 默认给你 root。root 去读别人的
`/proc/1/fd` 会被拒，输出 `Permission denied`；如果顺手加了 `2>/dev/null`，就变成**什么都没有** ——
和"确实没有句柄"在输出上一模一样。我第一次跑脚本就是这么得出错误结论的。
正确做法是 `docker compose exec -u mysql ...`。

> 这一条是这次实测才发现的，`inject/disk-full-fix.sh` 里已经专门处理：读到 `Permission denied` 会单独报出来，
> 而不是静默当成"没有"。

## 根因

Linux 回收一个文件的数据块，要**同时**满足两个条件：

- `i_nlink == 0`：没有目录项指向这个 inode（`rm` 干的事）
- `refcount == 0`：没有进程持有它的 fd（`close` 干的事）

`rm` 之后 `nlink` 立刻归零，但 mysqld 的 fd 还开着，`refcount` 还是 1，条件缺一，数据块一个都不回收。

- `df` 遍历文件系统元数据，统计**已分配的块** → 不变
- `du` 遍历目录树，统计**能看到的文件** → 变小

所以"删了没用"不是文件系统的锅，是**删除和关闭本来就是两件事**。

还有一个实测结论值得记：**8.0.46 和 8.4.11 在慢日志写失败时都不会自动关闭慢日志。**
只报一条 `MY-010907` 然后继续跑，`slow_query_log` 一直是 `ON`，fd 一直挂着 —— 盘满之后句柄
**不会自己消失**，必须有人主动关。这让故障"必然发生"，也让处置动作成为必需。

## 防复发

**止血顺序（不重启）：**

1. `df` + `du` 同时看，对不上就去 `/proc/<pid>/fd` 找 `(deleted)`（注意用 `-u mysql`）
2. 能安全回收的先回收：`PURGE BINARY LOGS BEFORE '...'`（**不要 `rm` binlog 文件**，索引会不一致）、
   旧 relay log、旧备份
3. 慢日志：`mv slow.log slow.log.1` + `FLUSH SLOW LOGS`，或者 `SET GLOBAL slow_query_log=OFF` 后删
4. 腾出空间后再扩盘，别把扩盘当第一动作

**三种删日志方式，只有一种是对的：**

| 做法 | 空间立即释放 | 说明 |
|---|---|---|
| `rm slow.log` | **否** | fd 还在，白删 |
| `: > slow.log` | 是 | truncate 不改 inode，紧急可用；官方不支持，可能留稀疏空洞 |
| `mv` + `FLUSH SLOW LOGS` | 是 | **标准做法**，旧 fd 关闭、新 inode 建立 |

**配置层面：**

- 慢日志放**独立挂载点**并给容量上限 —— 但这会掩盖本次故障链（见下面第 4 题），取舍要想清楚
- `logrotate` 配 `postrotate mysqladmin flush-logs`，**不要用 `copytruncate`**（和写入偏移打架）
- `long_query_time` 不低于 1；`log_queries_not_using_indexes` 必须配
  `log_throttle_queries_not_using_indexes` + `min_examined_row_limit`
- 大 SQL 治理：批量 `INSERT` 拆批、`IN` 列表控长度。一条 500KB 的 SQL 在慢日志里就是一条 500KB 的记录
- 监控补两项：慢日志文件大小**增速**（不只是当前大小）、`lsof +L1` 的已删除文件总量

**不要做：**

- `rm` 完就以为处理完了
- 用"能不能 INSERT 一条"判断盘满
- 盘满时立刻重启 —— 很可能起不来，初始化 binlog 和临时文件都要写空间
- `kill -9 mysqld` —— crash recovery 比正常重启慢得多

## 这次没有证明的事

原定的"binlog 和 redo 谁先写不进去"没有测。这次盘满是被 filler 一次性打满的，
没有观察 redo 循环写和 binlog 增长在同一块盘上抢空间的先后顺序。

下一步要在同一套环境上补：把 `innodb_redo_log_capacity` 调小、开 `sync_binlog=1`，
然后缓慢逼近 `ENOSPC`，看谁先报错。这是 05 的另一半。

## 自己再答一遍（不看上面）

1. `df` 显示 100%，`du` 加起来只有一半。这两个数差在哪，说明什么？
2. 删掉慢日志之后 `df` 会降吗？为什么？
3. 磁盘满时 `INSERT` 一条成功了，能不能说明盘没满？为什么？
4. 慢日志在独立盘上，那个盘满了，业务会挂吗？这个答案会怎么改变你的监控设计？
5. 除了关慢日志，还有哪两种方式能让那个 inode 的 `refcount` 归零？各自的代价是什么？
6. 盘满时为什么不能重启？「起不来」具体卡在哪一步？
