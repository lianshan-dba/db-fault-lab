#!/usr/bin/env bash
# 「02 的现场还在吗」—— 还有 SELECT SLEEP(600) 挂在那儿就说明注入过。
set -uo pipefail
cd "$(dirname "$0")"    # 只用到 docker exec，不依赖 compose 文件

n=$(docker exec dfl-02-mdl mysql -uroot -prootpass -N -B -e "
  SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE '%SLEEP(600)%'
" 2>/dev/null | tr -d '\r')
[ -n "${n:-}" ] && [ "$n" -gt 0 ]
