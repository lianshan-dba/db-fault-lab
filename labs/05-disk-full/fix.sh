#!/usr/bin/env bash
# 实验 05 的处置：不重启实例，把被句柄卡住的空间放回来
#
# 先按 inject.sh 末尾那几个问题自己试一遍，再跑这个对答案。
# 三段：先演「直觉做法为什么没用」，再演「正确做法为什么有效」，最后讲机制。
set -euo pipefail
cd "$(dirname "$0")/../.."          # 回到仓库根：compose.yml 和 conf/ 都在这儿
COMPOSE="docker compose"                   # 一份 compose，服务靠 profiles 分组


SVC=mysql-disk-full
DB=demo
MYSQL="$COMPOSE exec -T -e MYSQL_PWD=rootpass $SVC mysql -uroot $DB"

if [ "$(docker inspect -f '{{.State.Running}}' dfl-05-disk-full 2>/dev/null || echo false)" != "true" ]; then
  echo "!! 容器 dfl-05-disk-full 没在跑。按顺序来："
  echo "     docker compose --profile 05 up -d"
  echo "     ./inject.sh"
  exit 1
fi

FSTYPE=$($COMPOSE exec -T "$SVC" stat -f -c %T /var/lib/mysql | tr -d '\r\n')
if [ "$FSTYPE" != "tmpfs" ]; then
  cat >&2 <<EOF
!! 停手：/var/lib/mysql 挂在 [$FSTYPE] 上，不是 tmpfs。
   这个脚本会删文件、会重新拉起写入，跑在真实磁盘上不安全。
EOF
  exit 1
fi

UP0=$($MYSQL -N -B -e "SHOW GLOBAL STATUS LIKE 'Uptime'" | awk '{print $2}')
echo "==> 0. 处置前的样子（Uptime ${UP0}s，最后用它证明没重启）"
$COMPOSE exec -T "$SVC" df -h /var/lib/mysql | tail -1

# ---------- 1. 直觉做法 ----------
echo
echo "==> 1. 大多数人的第一反应：rm 掉那个大日志"
$COMPOSE exec -T "$SVC" rm -f /var/lib/mysql/slow.log
sleep 1
echo "--- df（文件系统还剩多少）"
$COMPOSE exec -T "$SVC" df -h /var/lib/mysql | tail -1
echo "--- du（目录里还剩什么）"
$COMPOSE exec -T "$SVC" du -sh /var/lib/mysql
echo "    ↑ du 掉了，df 一点没动。这就是那个坑。"

# ---------- 2. 证据 ----------
echo
echo "==> 2. 为什么：谁还开着这个已经删掉的文件"
# 坑：mysqld 在容器里以 mysql 用户跑，而 $COMPOSE exec 默认给 root。
# root 读别人的 /proc/1/fd 会被拒，输出是 "Permission denied"；
# 如果顺手 2>/dev/null，就变成「什么都没有」——和「确实没有句柄」长得一模一样。
# 所以这里显式 -u mysql，并且把权限不足这种情况单独报出来。
FD_LIST=$($COMPOSE exec -T -u mysql "$SVC" bash -c 'ls -l /proc/1/fd 2>&1') || true
if printf '%s' "$FD_LIST" | grep -q 'Permission denied'; then
  echo "    !! 读不到 /proc/1/fd（权限不足），这不等于没有句柄。"
  echo "    !! 换成 -u mysql 再读一次，否则你会得出完全相反的结论。"
else
  printf '%s\n' "$FD_LIST" | grep 'deleted' | sed 's/^/    /' || echo "    （没有 deleted 句柄）"
  echo "    注：/tmp/#NNN 那些是 InnoDB 自己的临时文件句柄，和这次故障无关，别被它们带偏 ——"
  echo "        要找的是那个大的、你刚删掉的那个文件。"
fi
echo "    nlink 已经是 0，但这个 fd 还引用着 inode，数据块一个都不还。"

# ---------- 3. 正确做法 ----------
echo
echo "==> 3. 不重启，只关慢日志 —— 等于让 mysqld 执行 close(fd)"
$MYSQL -e "SET GLOBAL slow_query_log = OFF;"
sleep 1
echo "--- df"
$COMPOSE exec -T "$SVC" df -h /var/lib/mysql | tail -1
echo "--- 还有没有 slow.log 的句柄（精确匹配 slow.log，不是 slow）"
$COMPOSE exec -T -u mysql "$SVC" bash -c \
  'ls -l /proc/1/fd 2>/dev/null | grep "slow\.log" || echo "    没有 slow.log 句柄了"'

# ---------- 4. 清理与恢复 ----------
echo
echo "==> 4. 清掉人为的 filler（真实场景里对应大事务结束时自己释放的临时文件）"
$COMPOSE exec -T "$SVC" rm -f /var/lib/mysql/filler.bin
$COMPOSE exec -T "$SVC" df -h /var/lib/mysql | tail -1

echo
echo "==> 5. 阈值改回正常值，重新开慢日志"
$MYSQL -e "
SET GLOBAL long_query_time     = 1;
SET GLOBAL slow_query_log_file = '/var/lib/mysql/slow.log';
SET GLOBAL slow_query_log      = ON;"

echo
echo "==> 6. 验证业务恢复"
$MYSQL -e "
INSERT INTO t_big(pad) SELECT REPEAT('y',1100) FROM information_schema.columns LIMIT 5000;
SELECT ROW_COUNT() AS affected_rows;
SELECT COUNT(*) AS rows_now FROM t_big;" 2>&1 | tail -4 || true
$COMPOSE exec -T "$SVC" ls -lh /var/lib/mysql/slow.log | awk '{print "    新慢日志: "$5"\t"$9}'

UP1=$($MYSQL -N -B -e "SHOW GLOBAL STATUS LIKE 'Uptime'" | awk '{print $2}')
echo
echo "==> 7. 实例重启过没有"
echo "    Uptime: ${UP0}s → ${UP1}s，单调增长，说明全程没重启。"

cat <<'EOF'

========== 为什么 ==========

Linux 回收数据块，要同时满足两个条件：

  i_nlink  == 0    没有目录项指向这个 inode      —— rm 干的
  refcount == 0    没有进程持有它的 fd           —— close 干的

rm 只做到第一个。mysqld 的 fd 还开着，refcount 还是 1，块一个都不还。

  df  统计文件系统里「已分配的块」  → 不变
  du  统计目录树里「能看到的文件」  → 变小

两个数对不上，唯一解释就是有进程持着已删除的 inode。
所以这不是文件系统的锅，是「删除」和「关闭」本来就是两件事。

三种删法，只有一种是对的：

  rm slow.log            不释放   fd 还在，白删
  : > slow.log           释放     truncate 不动 inode；能救急，官方不支持，可能留稀疏空洞
  mv + FLUSH SLOW LOGS   释放    标准做法：旧 fd 关掉，新 inode 建起来

本实验用的是第四种：SET GLOBAL slow_query_log=OFF 再 ON。
它和 mv+FLUSH 等价（都是关 fd、开新文件），好处是不用碰文件系统。

========== 轮到你了 ==========

  1. 同样是被句柄卡住的 binlog，能用 rm 吗？PURGE BINARY LOGS 和 rm 的区别到底是什么？
     为什么删 binlog 文件会让从库断流得更惨？

  2. 如果卡住的是错误日志（log_error），能 SET GLOBAL 关掉吗？不能的话怎么办？

  3. 盘满时为什么不该重启？把「起不来」的具体原因说清楚（提示：启动要写哪些文件）。

  4. 把故障往前推一步：慢日志所在盘满，但 datadir 在另一个盘，业务会挂吗？
     这个答案会改变你的监控设计。

重置重练：./lab.sh reset 05 && ./lab.sh use 05   （原地复原，不重建容器）
EOF
