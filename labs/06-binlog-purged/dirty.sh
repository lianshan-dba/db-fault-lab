#!/usr/bin/env bash
# 「06 的现场还在吗」—— 从库 IO 线程不是 Yes 就说明断流过。
#
# 这里必须看 IO 线程，不能只看 SQL 线程：这个故障的典型迷惑点就是
# SQL 线程依然 Yes，看起来「复制没挂」。
set -uo pipefail
cd "$(dirname "$0")"    # 只用到 docker exec，不依赖 compose 文件

out=$(docker exec dfl-06-slave mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" 2>/dev/null) || exit 1
[ -n "${out:-}" ] || exit 1     # 还没建过复制，谈不上「现场」

io=$(printf '%s\n' "$out" | awk -F': ' '/Replica_IO_Running:/{print $2; exit}' | tr -d '\r')
[ "${io:-No}" != "Yes" ]
