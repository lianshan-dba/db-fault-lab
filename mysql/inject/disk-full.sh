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
docker compose exec -T "$SVC" df -h /var/lib/mysql | tail -1
echo "--- du：目录视角"
docker compose exec -T "$SVC" du -sh /var/lib/mysql
echo "    注意到没有：此刻 df 的 Used 和 du 是**相等**的（上面两个数一样，差几 MB 是四舍五入）。"
echo "    什么都还没删，两边看到的是同一批文件。分叉要等你 rm 掉 slow.log 之后才出现。"
echo "--- 两个大文件各占多少"
docker compose exec -T "$SVC" ls -lh /var/lib/mysql/slow.log /var/lib/mysql/filler.bin \
  | awk '{print "    "$5"\t"$9}'

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

cat <<'EOF'

========== 现在轮到你 ==========

盘满了，实例还活着，慢日志也还开着。接下来别急着敲命令，先回答：

  0. 先登进去看一眼（在外面看 df 是不够的）：
       容器内：docker exec -it dfl-disk-full mysql -uroot -prootpass demo
       宿主机：mysql -h127.0.0.1 -P13309 -uroot -prootpass demo   ← 装客户端才有
     账号 root / rootpass，库 demo。GUI 也是这套，端口 13309。

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

自己试完再对答案，完整演示一遍处置：在仓库根跑 ./lab.sh use 05 fix

重置重练：./lab.sh reset 05 && ./lab.sh use 05   （原地复原，不重建容器）
换别的故障：./lab.sh use 01 / use 02
记到 docs/05-disk-full.md
EOF
