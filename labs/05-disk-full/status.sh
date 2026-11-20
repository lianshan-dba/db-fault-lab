#!/usr/bin/env bash
# 05 的状态：盘用了多少、两个大文件还在不在、是不是已经注入过。
# 由 ./lab.sh status 调用，输出会被缩进显示。
set -uo pipefail
LAB_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$LAB_DIR/../.."          # 回到仓库根：compose.yml 和 conf/ 都在这儿
COMPOSE="docker compose"     # 一份 compose，服务靠 profiles 分组

echo "盘（tmpfs 768M）:"
$COMPOSE exec -T mysql-disk-full sh -c '
  df -h /var/lib/mysql | tail -1
  du -sh /var/lib/mysql
  ls -lh /var/lib/mysql/slow.log /var/lib/mysql/filler.bin 2>/dev/null | awk "{print \"    \"\$5\"\t\"\$9}"
' 2>/dev/null | sed 's/^/    /'
if "$LAB_DIR/dirty.sh"; then
  echo "    状态：已注入（练完用 ./lab.sh reset 05 复原）"
else
  echo "    状态：干净"
fi
