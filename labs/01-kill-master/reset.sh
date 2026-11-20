#!/usr/bin/env bash
# 01 的复原：等主库被 docker 拉起来，然后把复制重新接上。
#
# 01 的注入是「kill -9 主库」，它自己会 recover 并重连 —— 所以复原不是撤销什么，
# 而是把复制关系确认一遍：Last_IO_Error 还挂着就重建，从库可能停在半路。
set -euo pipefail
cd "$(dirname "$0")/../.."          # 回到仓库根：compose.yml 和 conf/ 都在这儿
COMPOSE="docker compose"                   # 一份 compose，服务靠 profiles 分组

echo "==> 等主库就绪（被 kill 之后 docker 会自动拉起，约 10～30 秒）"
i=0
while [ "$i" -lt 120 ]; do
  h=$(docker inspect -f '{{.State.Health.Status}}' dfl-01-master 2>/dev/null || echo none)
  [ "$h" = "healthy" ] && break
  sleep 2; i=$((i + 2))
done
if [ "${h:-none}" != "healthy" ]; then
  echo "!! 主库 120 秒还没 healthy。看日志：docker logs --tail=40 dfl-01-master"
  exit 1
fi
echo "    主库 healthy"

echo
echo "==> 重建复制关系（顺便把从库的 super_read_only 重新打开）"
./scripts/init-replica.sh | tail -12

echo
echo "==> 复原后：主库 Uptime（新进程，从 0 开始算）"
$COMPOSE exec -T mysql-master mysql -uroot -prootpass -e "SHOW GLOBAL STATUS LIKE 'Uptime'"

cat <<'EOF'

干净了：主库是新进程，两个从库都在复制。
再练一轮：./lab.sh use 01        （会在新的时间点上再 kill 一次）
换实验：./lab.sh use 05 / use 02
EOF
