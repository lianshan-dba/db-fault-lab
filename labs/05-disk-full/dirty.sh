#!/usr/bin/env bash
# 「05 的现场还在吗」—— 返回 0 表示已经注入过。
#
# 判断依据：慢日志被灌到 300M+ 了。只认这一条，别用 df，
# 因为盘满也可能是别的东西撑的，那不该触发复原。
set -uo pipefail
cd "$(dirname "$0")"    # 只用到 docker exec，不依赖 compose 文件

sz=$(docker exec dfl-05-disk-full stat -c %s /var/lib/mysql/slow.log 2>/dev/null | tr -d '\r')
[ -n "${sz:-}" ] && [ "$sz" -gt 52428800 ]
