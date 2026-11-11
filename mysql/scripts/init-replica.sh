#!/usr/bin/env bash
# 把两个从库接到主库上（GTID 自动定位，不需要记 binlog 位点）
set -euo pipefail
cd "$(dirname "$0")/.."

for slave in mysql-slave-1 mysql-slave-2; do
  echo "==> ${slave} 建立复制关系"
  docker compose exec -T "$slave" mysql -uroot -prootpass -e "
    STOP REPLICA;
    RESET REPLICA ALL;
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST='mysql-master',
      SOURCE_PORT=3306,
      SOURCE_USER='repl',
      SOURCE_PASSWORD='replpass',
      SOURCE_AUTO_POSITION=1;
    START REPLICA;
  "
done

echo
echo "==> 等 3 秒后检查状态"
sleep 3
for slave in mysql-slave-1 mysql-slave-2; do
  echo "---- ${slave}"
  docker compose exec -T "$slave" mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error|Last_IO_Error' || true
done

# 复制建好之后再上锁：配置文件里不能提前写 super-read-only，
# 否则官方镜像初始化时执行 ALTER USER 会报 ERROR 1290 直接退出。
echo
echo "==> 从库上锁（super_read_only）"
for slave in mysql-slave-1 mysql-slave-2; do
  docker compose exec -T "$slave" mysql -uroot -prootpass -e \
    "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null \
    && echo "    ${slave}: super_read_only=ON"
done

echo
echo "两个都 Replica_IO_Running: Yes / Replica_SQL_Running: Yes 就通了。"
echo "不通的话先看 Last_IO_Error，九成是 repl 用户或网络别名的问题。"
