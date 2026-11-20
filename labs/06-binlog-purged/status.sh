#!/usr/bin/env bash
# 06 的状态：复制两个线程通不通、落后多少，主库还剩几个 binlog。
set -uo pipefail
cd "$(dirname "$0")/../.."
COMPOSE="docker compose"

rs=$($COMPOSE exec -T -e MYSQL_PWD=rootpass mysql-binlog-slave mysql -uroot \
      -e "SHOW REPLICA STATUS\G" 2>/dev/null \
  | grep -E '^[[:space:]]*(Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error): ' || true)
if [ -z "${rs:-}" ]; then
  echo "复制：还没建（./lab.sh use 06 会建）"
else
  echo "复制（mysql-binlog-slave）:"
  printf '%s\n' "$rs" | sed 's/^/    /'
fi

n=$($COMPOSE exec -T -e MYSQL_PWD=rootpass mysql-binlog-master mysql -uroot -N -B \
      -e "SELECT COUNT(*) FROM information_schema.BINARY_LOGS" 2>/dev/null | tr -d '\r')
[ -n "${n:-}" ] && echo "主库 binlog：$n 个"
