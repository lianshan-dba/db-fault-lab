#!/usr/bin/env bash
# 实验 05：磁盘写满 → 删掉大文件 → df 死活不降
#
# 这个实验要在「容量可控的盘」上跑，所以用的是独立实例 mysql-disk-full，
# 它的 datadir 挂在 768M 的 tmpfs 上。别拿 mysql-master 做 —— 那是 named volume，
# 容量跟着宿主磁盘走，想造 ENOSPC 就得把你自己机器的盘填满。
#
#   cd mysql
#   docker compose up -d mysql-disk-full      # 只起这一个
#   ./inject/disk-full.sh
#
# 为什么不用 --profile disk-full up -d：那样会把没写 profile 的服务（一主两从）
# 一起拉起来，白等 60 秒初始化。只写服务名就只起那一个。
# 从仓库根目录跑更省事：./lab.sh use 05（复用常驻环境，不重建容器）
set -euo pipefail
cd "$(dirname "$0")/.."

SVC=mysql-disk-full
DB=demo
# 密码走环境变量。否则每条输出的第一行都是 "Using a password ..."，
# 现场就埋在这堆 warning 里看不清了。
MYSQL="docker compose exec -T -e MYSQL_PWD=rootpass $SVC mysql -uroot $DB"

avail_bytes() {
  docker compose exec -T "$SVC" df -B1 --output=avail /var/lib/mysql | awk 'NR==2{print $1+0}'
}
slow_size() {
  docker compose exec -T "$SVC" stat -c %s /var/lib/mysql/slow.log 2>/dev/null | tr -d '\r'
}

# ---------- 0. 前置检查 ----------
if [ "$(docker inspect -f '{{.State.Running}}' dfl-disk-full 2>/dev/null || echo false)" != "true" ]; then
  echo "!! 容器 dfl-disk-full 没在跑。先执行："
  echo "     docker compose up -d mysql-disk-full"
  exit 1
fi

FSTYPE=$(docker compose exec -T "$SVC" stat -f -c %T /var/lib/mysql | tr -d '\r\n')
if [ "$FSTYPE" != "tmpfs" ]; then
  cat >&2 <<EOF
!! 停手：/var/lib/mysql 现在挂在 [$FSTYPE] 上，不是 tmpfs。

   这个脚本会把所在文件系统写到 100%。跑在真实磁盘上，等于把你自己的
   MySQL 数据目录撑爆，而且它不会自己恢复。

   正确起法：docker compose up -d mysql-disk-full
   如果之前改过 compose 里的 tmpfs size，要先 rm -sf 重建容器才会生效。
EOF
  exit 1
fi
echo "==> 0. 前置检查通过：datadir 在 tmpfs 上，盘满只发生在容器内存里"

# ---------- 1. 准备 ----------
echo
echo "==> 1. 建一张宽表，把慢日志开到最啰嗦的档位"
$MYSQL -e "
CREATE TABLE IF NOT EXISTS t_big (
  id  INT PRIMARY KEY AUTO_INCREMENT,
  pad VARCHAR(1200)
) ENGINE=InnoDB;
SET GLOBAL slow_query_log      = OFF;
SET GLOBAL slow_query_log_file = '/var/lib/mysql/slow.log';
SET GLOBAL long_query_time     = 0;
SET GLOBAL log_slow_extra      = ON;
SET GLOBAL slow_query_log      = ON;
"
# long_query_time 故意设 0：让每条查询都进慢日志，否则灌不动。
# 真实故障里慢日志暴涨通常不是因为阈值低，而是大 SQL（批量 INSERT、IN 列表过长）。

# ---------- 2. 灌慢日志 ----------
AVAIL0=$(avail_bytes)
TARGET=$(( AVAIL0 * 55 / 100 ))

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
head -c 400000 /dev/zero | tr '\0' 'x' > "$WORK/pad"
{ printf "SELECT '"; cat "$WORK/pad"; printf "';\n"; } > "$WORK/one.sql"
for _ in $(seq 1 50); do cat "$WORK/one.sql"; done > "$WORK/batch.sql"

echo
echo "==> 2. 灌慢日志：可用 $(( AVAIL0 / 1024 / 1024 ))M，目标占 55%（约 $(( TARGET / 1024 / 1024 ))M）"
# 每批 50 条 400KB 的查询。灌到目标就停 —— 不按条数估算，直接看文件实际大小，
# 否则 SQL 长度一变，估算就偏了，容易一不小心把盘灌爆在慢日志这一步。
round=0
while :; do
  cur=$(slow_size); cur=${cur:-0}
  if [ "$cur" -ge "$TARGET" ]; then break; fi
  round=$(( round + 1 ))
  if [ "$round" -gt 120 ]; then echo "    轮数超限，先停下"; break; fi
  $MYSQL --force < "$WORK/batch.sql" > /dev/null 2>&1 || true
  printf "\r    慢日志 %3dM / 目标 %3dM" "$(( cur / 1048576 ))" "$(( TARGET / 1048576 ))"
done
printf "\r    慢日志 %3dM / 目标 %3dM，灌入完成\n" "$(( $(slow_size) / 1048576 ))" "$(( TARGET / 1048576 ))"

# ---------- 3. 补刀 ----------
AVAIL1=$(avail_bytes)
FILL=$(( AVAIL1 - 2 * 1024 * 1024 ))
echo
echo "==> 3. 用 filler 把剩下 $(( FILL / 1048576 ))M 吃干"
echo "    真实场景里这个是 binlog 暴涨 / 大事务 / 磁盘临时表。用一个文件代替，"
echo "    只为精确停在 100%，并保证慢日志是在「写入还成功」的状态下被卡住的。"
# 这个镜像里没有 fallocate（Oracle Linux minimal 不带全套 util-linux），用 dd。
# tmpfs 上 dd 就是内存拷贝，几百兆一两秒。
docker compose exec -T "$SVC" dd if=/dev/zero of=/var/lib/mysql/filler.bin \
  bs=1M count=$(( FILL / 1048576 )) status=none

# ---------- 4. 现场 ----------
echo
echo "========== 现在的现场 =========="
echo "--- df：文件系统视角"
DF_LINE=$(docker compose exec -T "$SVC" df -h /var/lib/mysql | tail -1)
echo "$DF_LINE"
echo "--- du：目录视角"
DU_NOW=$(docker compose exec -T "$SVC" du -sh /var/lib/mysql | awk '{print $1}')
printf '    %s\t/var/lib/mysql\n' "$DU_NOW"
echo "    注意到没有：此刻 df 的 Used 和 du 是**相等**的（上面两个数一样，差几 MB 是四舍五入）。"
echo "    什么都还没删，两边看到的是同一批文件。分叉要等你 rm 掉 slow.log 之后才出现。"
echo "--- 两个大文件各占多少"
docker compose exec -T "$SVC" ls -lh /var/lib/mysql/slow.log /var/lib/mysql/filler.bin \
  | awk '{print "    "$5"\t"$9}'

# 下面「照着敲」那一节要写真实的数字：删了 slow.log 之后 du 会掉多少、df 的 Used 现在是多少。
# 编一个大概值最省事，但用户一对照就发现对不上，那这套脚本就没人信了。
SLOW_H=$(docker compose exec -T "$SVC" du -h /var/lib/mysql/slow.log | awk '{print $1}')
DF_USED=$(printf '%s' "$DF_LINE" | awk '{print $3}')

echo
echo "--- 业务写入的三种表现（注意差别，第 1 条会骗人）"
# 注意：mysql 在非交互模式下不打印 "Query OK"，所以成功的语句要自己把影响行数选出来，
# 否则「单行插入成功了」这件事在输出里完全看不出来，而它恰恰是这个实验最反直觉的一步。
echo "[1] 单行 INSERT（看 affected_rows）"
$MYSQL -e "INSERT INTO t_big(pad) VALUES (REPEAT('y',1100)); SELECT ROW_COUNT() AS affected_rows;" 2>&1 \
  | tail -2 || true
echo "[2] 批量 INSERT 5000 行（要扩 .ibd）"
$MYSQL -e "INSERT INTO t_big(pad) SELECT REPEAT('y',1100) FROM information_schema.columns LIMIT 5000;" 2>&1 \
  | tail -2 || true
echo "[3] CREATE TABLE"
$MYSQL -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB;" 2>&1 \
  | tail -2 || true

echo
echo "--- 慢日志还开着吗（这一条决定后面救不救得回来）"
$MYSQL -e "SHOW VARIABLES WHERE Variable_name IN ('slow_query_log','slow_query_log_file');"

echo
echo "--- 服务端日志里的相关记录"
docker compose logs --tail=300 "$SVC" 2>&1 \
  | grep -E 'errno: 28|No space|MY-010907|disk is full' | tail -6 \
  || echo "    （没抓到，手动看：docker compose logs $SVC）"

# ---------- 5. 照这个敲：命令 → 你会看到的报错 ----------
# 光写"单行能插进去、批量会失败"没有用，用户要的是能直接粘进终端的命令，
# 和粘进去之后屏幕上会出现的原文。所以这一段把命令和预期输出成对给出。
cat <<EOF

========== 现在轮到你（一）：先把现象复现出来，别急着删 ==========

  下面每条都能直接粘进终端。报错和输出是这台机器刚才跑出来的原文。

  ① 盘满没满：df 和 du 必须一起看，这是后面所有判断的起点
       \$ docker exec -it dfl-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
     ${DF_LINE}
     ${DU_NOW}	/var/lib/mysql
     → 两个数一样。此刻还什么都没删，相等是正常的，别以为脚本没生效。

  ② 单行 INSERT：会成功。这就是这个故障最坑的地方
       \$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \\
           -e "INSERT INTO t_big(pad) VALUES (REPEAT('y',1100))"
     → 屏幕上什么都没有。非交互模式下 mysql 不打印 Query OK，没输出就是成功。
       想看行数就自己选出来：
       \$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \\
           -e "INSERT INTO t_big(pad) VALUES (REPEAT('y',1100)); SELECT ROW_COUNT() AS affected_rows;"
       affected_rows
       1

     每条 mysql 命令前都会多打印一行
       mysql: [Warning] Using a password on the command line interface can be insecure.
     那是"命令行里带密码"的提示，不是错误，忽略它。

  ③ 批量 INSERT 5000 行：要扩 .ibd，立刻失败
       \$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \\
           -e "INSERT INTO t_big(pad) SELECT REPEAT('y',1100) FROM information_schema.columns LIMIT 5000"
     ERROR 1114 (HY000) at line 1: The table 't_big' is full

  ④ CREATE TABLE：同样失败，但报的是另一个错号
       \$ docker exec -it dfl-disk-full mysql -uroot -prootpass demo \\
           -e "CREATE TABLE t_new (id INT) ENGINE=InnoDB"
     ERROR 3675 (HY000) at line 1: Create table/tablespace 't_new' failed, as disk is full

  ② 成功、③④ 失败、而 df 已经 100% —— 三个现象同时成立，才是"盘满"的完整证据。
  只凭 ② 就下结论"盘没问题"，是这类故障里最常见的误判。

  ⑤ 服务端日志里只有一条，不会自己关慢日志
       \$ docker logs dfl-disk-full 2>&1 | grep -E 'errno: 28|MY-010907' | tail -3
     [ERROR] [MY-010907] [Server] Error writing file '/var/lib/mysql/slow.log' (errno: 28 - No space left on device)
     → 只报错，不停写、也不自动关慢日志（8.0.46 / 8.4.11 都一样），所以那个 fd 会一直挂着。

EOF

cat <<'EOF'

========== 现在轮到你（二）：先写预测，再去动手 ==========

盘满了，实例还活着，慢日志也还开着。动手之前先回答（答不上来就带着问题往下做）：

  1. 三类占用分得清吗？
     MySQL 能自己回收的（purge binlog、旧 relay log）、只能 rm 的、
     rm 了也没用的 —— 各举一个，并说出为什么。

  2. 删掉慢日志之后，df 会降吗？先把预测写下来，再去删，然后对照。
     这是本实验的核心。猜错不要紧，知道为什么错才要紧。

  3. 如果 df 不降，下一个该看的证据是什么？
     提示：mysqld 在容器里是 1 号进程，但它以 mysql 用户跑；exec 默认给你的
     是 root，读 /proc/1/fd 会 Permission denied —— 而「读不到」和「没有」
     在输出上一模一样，先解决这个再下结论。
     进容器：docker compose exec -u mysql mysql-disk-full bash

  4. 不能重启（重启大概率起不来，初始化本身就要写空间）。
     不重启的前提下，怎么让那个 inode 的引用计数归零？有几种办法，各自代价是什么？

  5. 怎么在盘满之前发现？说两条能直接落地的监控，不要"加强监控"。

答案在下面（先写完预测再往下看）。
EOF

# 这一段要打印真实的 df / du 数字，所以必须用会展开变量的 heredoc。
cat <<EOF

========== 现在轮到你（三）：删了之后 ==========

  ⑥ 删掉慢日志，然后立刻再看一眼
       \$ docker exec -it dfl-disk-full rm -f /var/lib/mysql/slow.log
       \$ docker exec -it dfl-disk-full sh -c 'df -h /var/lib/mysql; du -sh /var/lib/mysql'
     ${DF_LINE}
     → df 一行和上面 ① 完全一样（Used 还是 ${DF_USED}，一个字都没变）；
       du 会小掉约 ${SLOW_H}（按块算，差几 M 是正常的，以你屏幕上的数为准）。
       删除确实生效了，空间没回来 —— 这个分叉就是整个实验的核心。

  ⑦ 找证据。这一步最容易得出错误结论，两种写法都试一遍
       \$ docker exec -it dfl-disk-full ls -l /proc/1/fd | grep 'slow\.log'
     ls: cannot open directory '/proc/1/fd': Permission denied
     → 默认给的是 root，读不到 mysqld 的 fd。屏幕上看不到，不等于句柄不存在。

       \$ docker exec -u mysql -it dfl-disk-full ls -l /proc/1/fd | grep 'slow\.log'
     l-wx------  1 mysql mysql 64 Nov 19 15:53 36 -> /var/lib/mysql/slow.log (deleted)
     → 认准 (deleted)。顺手看到的 /tmp/#NNN (deleted) 是 InnoDB 临时文件，一直在，别被它带偏。

  ⑧ 不重启，把空间要回来（下面三种写法任选一种）
       \$ docker exec -it dfl-disk-full mysql -uroot -prootpass -e "SET GLOBAL slow_query_log=OFF"
       \$ docker exec -it dfl-disk-full sh -c 'df -h /var/lib/mysql'
     → df 的 Used 会少掉约 ${SLOW_H}，Uptime 继续增长（没重启）。
       另外两种：mv slow.log slow.log.1 再 FLUSH SLOW LOGS（标准做法，要 RELOAD 权限）；
                 : > slow.log（不改 inode，能救急，官方不支持，可能留稀疏空洞）。

  ⑨ 对着看我的处置过程：./lab.sh use 05 fix
     然后复原重练：./lab.sh reset 05 && ./lab.sh use 05   （原地复原，不重建容器）
     换别的故障：./lab.sh use 01 / use 02
     记到 docs/05-disk-full.md（按「问题现象 / 思考方向 / 解决方法」三段写）
EOF
