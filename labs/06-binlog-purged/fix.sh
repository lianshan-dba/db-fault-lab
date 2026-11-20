#!/usr/bin/env bash
# 06 的处置演示（对答案）：先把证据看全，再走一遍恢复。
# 自己按 inject.sh 里的问题想完了再跑这个。
set -euo pipefail
cd "$(dirname "$0")/../.."
COMPOSE="docker compose"
SRC=mysql-binlog-master
DST=mysql-binlog-slave

q() { $COMPOSE exec -T -e MYSQL_PWD=rootpass "$1" mysql -uroot -e "$2"; }

echo "==> 1. 从库的原文报错（全库只有这一处会告诉你「缺数据」）"
q $DST "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Error' || true

echo
echo "==> 2. 主库：binlog 只剩当前这一个，gtid_purged 就是「我删到哪儿」"
q $SRC "SHOW BINARY LOGS"
q $SRC "SELECT @@gtid_purged\G"

echo "==> 3. 从库：它手上的 GTID 到哪儿（和上面差的那一段，永远补不回来）"
q $DST "SELECT @@gtid_executed\G"

cat <<'EOF'
----------------------------------------------------------------
结论：缺的那段事务，主库上已经不存在了。

  · SQL 线程还是 Yes，是因为它把手里的 relay log 应用完就闲着了。
    「SQL 线程 Yes」不等于复制健康，必须 IO / SQL 两个都 Yes。
  · 没有「跳过」这个选项：GTID 模式下 sql_slave_skip_counter 不生效；
    就算强行跳过，从库也会永久缺这段行，之后对不上账。
  · 唯一正确的动作是重做一次全量，拿一个带 GTID 位点的完整起点。
    大库用 XtraBackup / CLONE 插件，小库 mysqldump 就够。

下面是完整恢复过程（每一步都能写进工单）：
----------------------------------------------------------------
EOF

echo
"$(dirname "$0")/rebuild.sh"

cat <<'EOF'

----------------------------------------------------------------
最后一步别忘了对行数，别只看线程状态：
  docker exec -it dfl-06-master mysql -uroot -prootpass demo -e "SELECT COUNT(*) FROM t_pk"
  docker exec -it dfl-06-slave  mysql -uroot -prootpass demo -e "SELECT COUNT(*) FROM t_pk"
EOF
