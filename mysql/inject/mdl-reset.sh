#!/usr/bin/env bash
# 02 的复原：杀掉 mdl-block.sh 挂住的会话，把 ALTER 加上去的列撤掉。
#
# mdl-block.sh 用 docker compose exec -d 在容器里留了两个会话：
#   A：开了事务、摸过 t_pk、正在 SELECT SLEEP(600)
#   B：ALTER TABLE t_pk ADD COLUMN，卡在等 MDL
# 不清理的话，下一个实验（尤其 01）会莫名卡住，因为 t_pk 上还压着一把 MDL。
set -euo pipefail
cd "$(dirname "$0")/.."

M="docker compose exec -T -e MYSQL_PWD=rootpass mysql-master mysql -uroot demo"

if [ "$(docker inspect -f '{{.State.Running}}' dfl-master 2>/dev/null || echo false)" != "true" ]; then
  echo "!! 主库没在跑，没什么可复原的。要起环境：./lab.sh up"
  exit 0
fi

echo "==> 复原前：谁还挂着"
$M -e "
  SELECT ID, TIME, STATE, LEFT(INFO, 60) AS info
  FROM information_schema.PROCESSLIST
  WHERE ID <> CONNECTION_ID()
  ORDER BY TIME DESC LIMIT 10;
"

# 顺序很重要：先杀持锁的那个。
# 反过来的话，你杀了 ALTER，持有者还在睡，MDL 依然压着，下一个实验还是卡。
echo "==> 先杀持锁的会话（那个 SELECT SLEEP(600)）"
ids=$($M -N -B -e "
  SELECT ID FROM information_schema.PROCESSLIST
  WHERE INFO LIKE '%SLEEP(600)%'
" || true)
if [ -z "$ids" ]; then
  echo "    没有找到挂住的会话（可能已经自己结束了）"
else
  for id in $ids; do
    $M -e "KILL $id" || true
    echo "    已 KILL 会话 $id"
  done
fi

# 持锁的走了，卡着等 MDL 的 ALTER 会立刻继续执行完。
echo "==> 等 3 秒，让 ALTER 走完"
sleep 3

echo "==> 万一还有残留的 ALTER 会话，一并清掉"
ids=$($M -N -B -e "
  SELECT ID FROM information_schema.PROCESSLIST
  WHERE INFO LIKE 'ALTER TABLE%'
" || true)
for id in $ids; do
  $M -e "KILL $id" || true
  echo "    已 KILL 会话 $id"
done

# ALTER 可能已经成功，把列撤掉，回到初始化时的表结构
echo "==> 把 t_pk 的结构改回原样"
n=$($M -N -B -e "
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = 'demo' AND TABLE_NAME = 't_pk' AND COLUMN_NAME = 'note'
" || echo 0)
if [ "${n:-0}" -gt 0 ]; then
  $M -e "ALTER TABLE t_pk DROP COLUMN note"
  echo "    已删掉列 note"
else
  echo "    t_pk 上没有 note 列，不用改"
fi

echo
echo "==> 复原后"
$M -e "SHOW PROCESSLIST; SHOW CREATE TABLE t_pk\G"

cat <<'EOF'

干净了：没有挂住的会话，t_pk 回到初始结构。
接着练：./lab.sh use 02
换实验：./lab.sh use 05 / use 01
EOF
