#!/usr/bin/env bash
# 06 的恢复动作：从主库做一次全量，把从库重新接回去。
#
# 1236 缺的是「数据」，不是「配置」：那段 binlog 在主库上已经被删了，
# 所以没有「跳过这个事务」的解法（GTID 模式下也不允许跳）。
# 真实环境里大库用 XtraBackup / CLONE 插件，这里数据只有几 MB，
# mysqldump 足够，而且每一步都是能写进工单、能解释清楚的动作。
set -euo pipefail
cd "$(dirname "$0")/../.."
COMPOSE="docker compose"
SRC=mysql-binlog-master
DST=mysql-binlog-slave
DUMP=$(mktemp -t dfl06-dump.XXXXXX.sql)
trap 'rm -f "$DUMP"' EXIT

# MYSQL_PWD 传密码：命令行带 -p 会往每条命令前面插一行 warning，输出就没法看了
q() { $COMPOSE exec -T -e MYSQL_PWD=rootpass "$1" mysql -uroot -e "$2"; }

echo "==> 1. 从库停复制，并解除只读（否则 dump 灌不进去）"
q $DST "
  STOP REPLICA;
  RESET REPLICA ALL;
  SET GLOBAL super_read_only=OFF;
  SET GLOBAL read_only=OFF;
"

echo "==> 2. 清空从库已有的 GTID 记录（新快照自带 GTID_PURGED，不清会撞 ERROR 1840）"
q $DST "RESET MASTER" 2>/dev/null \
  || q $DST "RESET BINARY LOGS AND GTIDS"

echo "==> 3. 主库做一致性快照（--single-transaction 不锁业务表，--set-gtid-purged 带上位点）"
echo "    下一行 Warning: A partial dump ... 是 mysqldump 的标准提醒（只 dump 了 demo 库），不是错误"
$COMPOSE exec -T -e MYSQL_PWD=rootpass $SRC mysqldump -uroot \
  --single-transaction --set-gtid-purged=ON --databases demo > "$DUMP"
printf '    %s\t%s\n' "$(du -h "$DUMP" | cut -f1)" "快照"

echo "==> 4. 灌进从库"
$COMPOSE exec -T -e MYSQL_PWD=rootpass $DST mysql -uroot < "$DUMP"

echo "==> 5. 接上复制（从快照里的 GTID 位点往后追），顺手把只读打开"
q $DST "
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='$SRC', SOURCE_PORT=3306,
    SOURCE_USER='repl', SOURCE_PASSWORD='replpass',
    SOURCE_AUTO_POSITION=1;
  START REPLICA;
  SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;
"

echo "==> 6. 等 3 秒，看是不是真的通了"
sleep 3
q $DST "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error'
