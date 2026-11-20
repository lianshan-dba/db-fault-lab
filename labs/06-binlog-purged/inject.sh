#!/usr/bin/env bash
# 实验 06：主库把从库还没读到的 binlog 清掉了，从库一启动就 1236 断流。
#
# 现实里的成因就三种，本质是同一个 —— 从库要的那段日志，主库上已经没有了：
#   1) 从库停过（维护窗口 / 网络断 / IO 线程挂了），这期间主库照常写；
#   2) 主库 binlog_expire_logs_seconds 太小，日志自己到期被删；
#   3) 有人手工 PURGE BINARY LOGS 腾空间，没先看从库读到哪个文件。
# 这个实验演 1 + 3：停 IO 线程 → 主库继续写并切两轮日志 → PURGE → 放开 IO 线程。
#
# 环境定义在仓库根的 compose.yml（服务 mysql-binlog-master / mysql-binlog-slave，
# profiles: ["06"]），这个文件只负责造故障。
set -euo pipefail
cd "$(dirname "$0")/../.."          # 回到仓库根：compose.yml、conf/、scripts/ 都在这儿
COMPOSE="docker compose"
SRC=mysql-binlog-master
DST=mysql-binlog-slave

# 用 MYSQL_PWD 传密码，而不是 mysql -p：命令行带密码会让每条命令前面多一行
# 「Using a password ... can be insecure」的提示，十几条叠在一起就看不清现场了。
q() { $COMPOSE exec -T -e MYSQL_PWD=rootpass "$1" mysql -uroot -e "$2"; }

echo "==> 先确保复制是通的（几秒）"
./scripts/init-replica.sh "$SRC" "$DST" | tail -4

echo
echo "==> 主库现在有哪些 binlog（最后一个正在写）"
q $SRC "SHOW BINARY LOGS"

echo "==> 从库读到哪儿了"
q $DST "SHOW REPLICA STATUS\G" \
  | grep -E 'Source_Log_File|Retrieved_Gtid_Set|Executed_Gtid_Set'

echo
echo "==> 制造「从库落后」：停掉 IO 线程（等价于网络断 / 维护窗口里停了复制）"
q $DST "STOP REPLICA IO_THREAD"
q $DST "SHOW REPLICA STATUS\G" | grep -E 'Replica_IO_Running|Replica_SQL_Running'

echo
echo "==> 主库照常接业务：再写 4000 行，并切两轮 binlog"
q $SRC "
  USE demo;
  INSERT INTO t_pk (uid, amount) SELECT uid, amount FROM t_pk ORDER BY id LIMIT 2000;
  FLUSH BINARY LOGS;
  INSERT INTO t_pk (uid, amount) SELECT uid, amount FROM t_pk ORDER BY id DESC LIMIT 2000;
  FLUSH BINARY LOGS;
"

echo
echo "==> 运维为了腾空间，把「当前文件之前」的 binlog 全清掉"
# 用 PURGE ... TO 当前文件，而不是 BEFORE NOW()：后者按事件时间戳算，
# 刚写进去的日志可能还没「过期」，跑在同一个秒里就清不掉，实验会不稳定。
ACTIVE=$(q $SRC "SHOW BINARY LOGS" | awk 'NR>1 && NF {f=$1} END{print f}')
echo "    当前还在写的文件：$ACTIVE"
q $SRC "PURGE BINARY LOGS TO '$ACTIVE'"
echo "    清完之后只剩："
q $SRC "SHOW BINARY LOGS"

echo
echo "==> 网络恢复，从库重新去拉 binlog"
q $DST "START REPLICA IO_THREAD"
for i in 1 2 3 4 5; do
  echo "---- 第 ${i} 秒"
  q $DST "SHOW REPLICA STATUS\G" \
    | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Error' || true
  sleep 1
done

cat <<'EOF'

========== 现在的现场 ==========

  · 主库完全正常，业务照写 —— 这正是它危险的地方：没有报错、没人发现
  · 从库 Replica_SQL_Running 还是 Yes，看起来「复制没挂」
  · 只有 Replica_IO_Running: No + Last_IO_Error 里那行 1236

========== 现在轮到你（一）：把证据取全 ==========

  ① 从库到底报的什么错（原文，别转述）
       $ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
           | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Error'
     Replica_IO_Running: No
     Replica_SQL_Running: Yes
     Last_IO_Error: Got fatal error 1236 from source when reading data from binary log: 'Cannot
     replicate because the source purged required binary logs. Replicate the missing transactions
     from elsewhere, or provision a new replica from backup. Consider increasing the source's
     binary log expiration period. The GTID set sent by the replica is '<uuid>:1-13', and the
     missing transactions are '<uuid>:14-15''

     报错里那两串 uuid 是你这台机器的 GTID，以屏幕为准；关键是最后半句
     「missing transactions are ...」—— 主库直接告诉你缺哪几个事务。

  ② 主库还剩哪些 binlog、它自己「删到哪儿了」
       $ docker exec -it dfl-06-master mysql -uroot -prootpass \
           -e "SHOW BINARY LOGS; SELECT @@gtid_purged"

  ③ 两边 GTID 差在哪（差的那一段就是永远补不回来的）
       $ docker exec -it dfl-06-master mysql -uroot -prootpass -e "SELECT @@gtid_executed\G"
       $ docker exec -it dfl-06-slave  mysql -uroot -prootpass -e "SELECT @@gtid_executed\G"

========== 现在轮到你（二）：先写预测，再动手 ==========

  1. 从库的 SQL 线程为什么还是 Yes？它此刻在干什么？
  2. 缺的那段 binlog，在主库上还能找回来吗？看 ② 里的 gtid_purged。
  3. 能不能「跳过这个事务」绕过 1236？GTID 模式下为什么不行？
  4. 除了重做一次全量，还有哪些恢复手段？各自代价是什么？
  5. 这事怎么防？至少两条，一条在流程上、一条在参数上。

答案在下面（先写完预测再往下看）。

========== 现在轮到你（三）：恢复 ==========

  1236 缺的是「数据」，不是「配置」—— 没有跳过的解，只能拿一份完整数据重做从库。

  ④ 看一遍完整恢复过程（四步：停复制解只读 → 清 GTID 记录 → mysqldump 快照 → 灌回去接复制）
       $ ./lab.sh use 06 fix

  ⑤ 恢复完自己验：两个线程都 Yes、落后 0 秒
       $ docker exec -it dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" \
           | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source'

  ⑥ 别只看线程状态，主从行数要对得上
       $ docker exec -it dfl-06-master mysql -uroot -prootpass demo -e "SELECT COUNT(*) FROM t_pk"
       $ docker exec -it dfl-06-slave  mysql -uroot -prootpass demo -e "SELECT COUNT(*) FROM t_pk"

  ⑦ 复原重练：./lab.sh reset 06 && ./lab.sh use 06   （原地复原，不重建容器）
     换别的故障：./lab.sh use 01 / use 05
     记到 docs/06-binlog-purged.md（按「问题现象 / 思考方向 / 解决方法」三段写）
EOF
