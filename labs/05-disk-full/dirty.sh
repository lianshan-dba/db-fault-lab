#!/usr/bin/env bash
# 「05 的现场还在吗」—— 返回 0 表示注入过、还有得处置（或者已经处置了一半）。
#
# 不能拿 slow.log 判断：这个实验的核心动作就是 rm 掉它，删完现场其实还在
# （df 依然 100%，句柄还挂着）。所以认两个标志：
#   1) filler.bin 还在 —— 注入时用 dd 造的，reset 会删；
#   2) 盘还满着（>=95%）—— 用户可能自己清了 filler，但句柄没放，df 不会降。
# 任一成立就算「现场还在」。
set -uo pipefail
cd "$(dirname "$0")"    # 只用到 docker exec，不依赖 compose 文件

docker exec dfl-05-disk-full test -f /var/lib/mysql/filler.bin 2>/dev/null && exit 0

use=$(docker exec dfl-05-disk-full sh -c 'df -P /var/lib/mysql | tail -1' 2>/dev/null \
      | awk '{print $5}' | tr -d '% \r')
[ -n "${use:-}" ] && [ "$use" -ge 95 ]
