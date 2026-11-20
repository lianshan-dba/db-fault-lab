#!/usr/bin/env bash
# 01 的状态：两个从库的复制通不通。
set -uo pipefail
cd "$(dirname "$0")/../.."          # 回到仓库根：compose.yml 和 conf/ 都在这儿
COMPOSE="docker compose"                   # 一份 compose，服务靠 profiles 分组

rs=$($COMPOSE exec -T mysql-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" 2>/dev/null \
  | grep -E '^[[:space:]]*(Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error): ' || true)
if [ -z "${rs:-}" ]; then
  echo "复制：还没建（./lab.sh use 01 会建）"
else
  echo "复制（mysql-slave-1）:"
  printf '%s\n' "$rs" | sed 's/^/    /'
fi
