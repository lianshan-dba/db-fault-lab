#!/usr/bin/env bash
# 实验 01：把主库直接 kill -9
# 这不是"优雅停止"，是模拟机器掉电 / OOM killer / 进程崩溃
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 记录杀之前的复制状态"
for s in mysql-slave-1 mysql-slave-2; do
  echo "---- $s"
  docker compose exec -T "$s" mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source' || true
done

echo
echo "==> kill -9 主库（容器内 1 号进程）"
docker compose exec -T mysql-master bash -c 'kill -9 1' || true

echo "==> 观察从库立刻发生了什么（5 秒内）"
for i in 1 2 3 4 5; do
  echo "---- 第 ${i} 秒"
  docker compose exec -T mysql-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Error' || true
  sleep 1
done

echo
echo "接下来要你自己做的："
echo "  1. 把从库的 Last_IO_Error 原文抄下来（不要转述）"
echo "  2. 等主库被 docker 拉起来：docker compose ps"
echo "  3. 主库起来后，从库自己恢复了没有？多久恢复的？"
echo "  4. 这个过程中主库的 crash recovery 做了什么（错误日志里找）"
echo
echo "  记到 docs/01-kill-master.md"
