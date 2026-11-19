#!/usr/bin/env bash
# 把 05 的环境原地复原：删掉注入产生的大文件，参数改回默认。
#
# 关键点：不删容器、不重建 datadir。
#   重建容器 = tmpfs 变空 = 又要等 30 秒初始化；
#   原地复原 = 关慢日志 → rm 两个大文件 → 参数改回 = 一两秒。
#
# 这就是「环境常驻、用脚本切故障」的代价和收益：省掉重复的初始化，
# 换来一份要自己维护的复原脚本。写完这个脚本，05 才能反复练。
set -euo pipefail
cd "$(dirname "$0")/.."

SVC=mysql-disk-full
MYSQL="docker compose exec -T -e MYSQL_PWD=rootpass $SVC mysql -uroot demo"

if [ "$(docker inspect -f '{{.State.Running}}' dfl-disk-full 2>/dev/null || echo false)" != "true" ]; then
  echo "!! 容器 dfl-disk-full 没在跑，没什么可复原的。"
  echo "   要起环境：./lab.sh up"
  exit 0
fi

echo "==> 复原前"
docker compose exec -T "$SVC" df -h /var/lib/mysql | tail -1 | sed 's/^/    /'
docker compose exec -T "$SVC" du -sh /var/lib/mysql | sed 's/^/    /'

# 先关慢日志：这一步等于 close(fd)。
# 不先关就 rm，会变成「rm 了但空间没回来」——那不是复原失败，正是 05 要考的那个现象。
echo
echo "==> 关慢日志（先放句柄，再删文件）"
$MYSQL -e "SET GLOBAL slow_query_log = OFF;"

echo "==> 删掉注入留下的大文件"
docker compose exec -T "$SVC" sh -c '
  rm -f /var/lib/mysql/filler.bin /var/lib/mysql/slow.log
  echo "    filler.bin / slow.log 已删除"
'

# 空间腾出来了，才有地方写 DROP TABLE 的元数据
echo "==> 参数改回默认值，清掉注入建的表"
$MYSQL -e "
  SET GLOBAL long_query_time = 1;
  SET GLOBAL log_slow_extra  = OFF;
  DROP TABLE IF EXISTS t_big;
  DROP TABLE IF EXISTS t_new;
"
$MYSQL -e "
  SET GLOBAL slow_query_log_file = '/var/lib/mysql/slow.log';
  SET GLOBAL slow_query_log = ON;
"

echo
echo "==> 复原后"
docker compose exec -T "$SVC" df -h /var/lib/mysql | tail -1 | sed 's/^/    /'
docker compose exec -T "$SVC" du -sh /var/lib/mysql | sed 's/^/    /'
$MYSQL -e "SHOW VARIABLES LIKE 'slow_query_log%'; SELECT @@long_query_time AS long_query_time, @@log_slow_extra AS log_slow_extra;"

cat <<'EOF'

环境回到干净状态，容器没重建、datadir 没重新初始化。
接着练：./lab.sh use 05        （再来一遍）
换实验：./lab.sh use 01 / use 02
EOF
