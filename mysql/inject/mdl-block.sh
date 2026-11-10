#!/usr/bin/env bash
# 实验 02：造一个元数据锁（MDL）阻塞
# 最常见的线上"莫名其妙的卡死"：有人开了事务不提交，别人 ALTER 就卡在那儿，
# 后面的 SELECT 全部排队。表面上"数据库没响应"，实际是锁等待。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 会话 A：开事务、摸一下表、然后挂住 600 秒不提交"
docker compose exec -T -d mysql-master mysql -uroot -prootpass demo -e "
  START TRANSACTION;
  SELECT COUNT(*) FROM t_pk;
  SELECT SLEEP(600);
"

sleep 2

echo "==> 会话 B（后台）：执行 ALTER，它会卡住"
docker compose exec -T -d mysql-master mysql -uroot -prootpass demo -e "
  ALTER TABLE t_pk ADD COLUMN note VARCHAR(32) DEFAULT NULL;
" &

sleep 3

echo "==> 现在从第三个连接看，现场是什么样："
echo
echo "---- 1. 谁在等锁（performance_schema 是唯一能看清 MDL 的地方）"
docker compose exec -T mysql-master mysql -uroot -prootpass -e "
  SELECT
    OBJECT_SCHEMA, OBJECT_NAME, LOCK_TYPE, LOCK_DURATION, LOCK_STATUS,
    OWNER_THREAD_ID
  FROM performance_schema.metadata_locks
  WHERE OBJECT_SCHEMA = 'demo'\G
"

echo "---- 2. 把 THREAD_ID 换成具体会话（关键：找到 holding 的那个，不是 waiting 的）"
docker compose exec -T mysql-master mysql -uroot -prootpass -e "
  SELECT
    t.PROCESSLIST_ID, t.PROCESSLIST_STATE, t.PROCESSLIST_TIME,
    LEFT(t.PROCESSLIST_INFO, 80) AS info
  FROM performance_schema.threads t
  WHERE t.PROCESSLIST_ID IS NOT NULL
  ORDER BY t.PROCESSLIST_TIME DESC;
"

echo "---- 3. 常规手段看到的是什么（对比一下，看能不能定位）"
docker compose exec -T mysql-master mysql -uroot -prootpass -e "SHOW PROCESSLIST;"

cat <<'EOF'

接下来要你自己回答的：
  1. SHOW PROCESSLIST 里能看到"等 MDL"这件事吗？看到的是什么状态？
  2. 为什么 ALTER 会去等一个 SELECT 持有的锁？（提示：MDL 和行锁/表锁不是一回事）
  3. 找到 holding 的会话后，正确的处置顺序是什么？直接 KILL 会有什么后果？
  4. 这个场景怎么提前发现？（提示：等 5 秒以上的会话要告警）

收工：docker compose restart mysql-master
记到 docs/02-mdl-block.md
EOF
