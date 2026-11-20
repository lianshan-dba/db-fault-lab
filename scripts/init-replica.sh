#!/usr/bin/env bash
# 把从库接到主库上（GTID 自动定位，不需要记 binlog 位点）
#
#   ./scripts/init-replica.sh                                            # 01：mysql-master + 两个从库
#   ./scripts/init-replica.sh mysql-binlog-master mysql-binlog-slave     # 06：一对一
#
# 第一个参数是主库，后面全是从库；不给参数就用 01 的拓扑。
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE="docker compose"

if [ "$#" -ge 1 ]; then SOURCE=$1; shift; else SOURCE=mysql-master; fi
if [ "$#" -ge 1 ]; then SLAVES=("$@"); else SLAVES=(mysql-slave-1 mysql-slave-2); fi

for slave in "${SLAVES[@]}"; do
  echo "==> ${slave} 建立复制关系（源：${SOURCE}）"
  $COMPOSE exec -T -e MYSQL_PWD=rootpass "$slave" mysql -uroot -e "
    STOP REPLICA;
    RESET REPLICA ALL;
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST='${SOURCE}',
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
for slave in "${SLAVES[@]}"; do
  echo "---- ${slave}"
  $COMPOSE exec -T -e MYSQL_PWD=rootpass "$slave" mysql -uroot -e "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error|Last_IO_Error' || true
done

# 复制建好之后再上锁：配置文件里不能提前写 super-read-only，
# 否则官方镜像初始化时执行 ALTER USER 会报 ERROR 1290 直接退出。
echo
echo "==> 从库上锁（super_read_only）"
for slave in "${SLAVES[@]}"; do
  $COMPOSE exec -T -e MYSQL_PWD=rootpass "$slave" mysql -uroot -e \
    "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>/dev/null \
    && echo "    ${slave}: super_read_only=ON"
done

echo
echo "全部 Replica_IO_Running: Yes / Replica_SQL_Running: Yes 就通了。"
echo "不通的话先看 Last_IO_Error，九成是 repl 用户或网络别名的问题。"
