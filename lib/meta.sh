#!/usr/bin/env bash
# 实验元数据：labs/*/meta 是唯一「实验登记处」。
#
# lab.sh 不认实验号，也不认任何具体实验名 —— 它只读这份 meta。
# 所以加 06 的时候不用改 lab.sh 一行，新建 labs/06-xxx/ 写个 meta 就行。
#
# meta 是纯文本 KEY=VALUE，故意不去 source 它：
# 少一个能被任意执行的入口，读错一行也不会把脚本跑挂。
#
#   NB=05                                    实验号（也是目录前缀，lab.sh 靠它对号）
#   NAME=disk-full                           短名（英文，不加空格）
#   TITLE=磁盘写满 + 慢日志句柄未释放          一行标题，列清单时显示
#   DESC=独立实例，768M tmpfs                 一句话说明
#   PORTS="DISK_FULL_PORT:13309"             端口变量:默认值，多个用空格分隔
#   CONTAINERS="dfl-05-disk-full"            容器名，多个用空格分隔
#   CONN="描述|服务名|端口变量|容器名"         连接信息，多条用分号分隔

LABS_DIR="$LAB_ROOT/labs"

meta_get() { # $1=meta 文件 $2=键名
  awk -v k="$2" '
    /^[[:space:]]*#/ { next }
    {
      i = index($0, "=")
      if (i == 0) next
      key = substr($0, 1, i - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key != k) next
      val = substr($0, i + 1)
      sub(/[[:space:]]+#.*$/, "", val)          # 支持行内注释：PROFILE=05  # 说明
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val ~ /^".*"$/ || val ~ /^\047.*\047$/) val = substr(val, 2, length(val) - 2)
      print val
      exit
    }
  ' "$1"
}

# 列出所有实验：每行 "编号<TAB>目录<TAB>标题<TAB>说明"，按编号排序
labs_list() {
  local d nb
  for d in "$LABS_DIR"/*/; do
    [ -f "$d/meta" ] || continue
    nb=$(meta_get "$d/meta" NB)
    [ -n "$nb" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$nb" "labs/$(basename "$d")" \
      "$(meta_get "$d/meta" TITLE)" "$(meta_get "$d/meta" DESC)"
  done | sort -t$'\t' -k1,1
}

# 把编号解析成目录。接受 05 / 5 / 05-disk-full / disk-full
lab_find() { # $1=用户输入的实验号，成功时设置 LAB_DIR 与 LAB_META
  local want=$1 d nb name
  [ -n "$want" ] || die "要指定实验号，例如 ./lab.sh use 05（不知道有哪些：./lab.sh list）"
  for d in "$LABS_DIR"/*/; do
    [ -f "$d/meta" ] || continue
    nb=$(meta_get "$d/meta" NB)
    name=$(meta_get "$d/meta" NAME)
    case "$want" in
      "$nb"|"$(printf '%d' "$nb" 2>/dev/null)"|"$(basename "$d")"|"$name")
        LAB_DIR=${d%/}; LAB_META="$LAB_DIR/meta"; return 0 ;;
    esac
  done
  die "不认识的实验号：$want
   现有的：$(labs_list | cut -f1 | tr '\n' ' ')
   看清单和说明：./lab.sh list"
}

# 读 meta 到全局变量，顺便导出端口变量给 compose 用。
# 只在用户没显式设置时才用默认值，所以 DISK_FULL_PORT=23309 ./lab.sh use 05 依然有效。
lab_load() {
  LAB_NB=$(meta_get "$LAB_META" NB)
  LAB_PROFILE=$(meta_get "$LAB_META" PROFILE)
  [ -n "${LAB_PROFILE:-}" ] || LAB_PROFILE=$LAB_NB
  LAB_NAME=$(meta_get "$LAB_META" NAME)
  LAB_TITLE=$(meta_get "$LAB_META" TITLE)
  LAB_DESC=$(meta_get "$LAB_META" DESC)
  LAB_PORTS=$(meta_get "$LAB_META" PORTS)
  LAB_CONTAINERS=$(meta_get "$LAB_META" CONTAINERS)
  LAB_CONN=$(meta_get "$LAB_META" CONN)

  local p var def cur
  for p in $LAB_PORTS; do
    var=${p%%:*}; def=${p##*:}
    cur=${!var-}
    if [ -z "$cur" ]; then export "$var=$def"; else export "$var=$cur"; fi
  done
}

# 端口变量的当前值（已导出）
lab_port() { # $1=变量名
  printf '%s' "${!1-}"
}

# 所有实验共用仓库根这一份 compose.yml，实验之间靠 profiles 隔离。
#   lab_compose --profile 05 up -d     只起 05 的服务
#   lab_compose --profile 01 up -d     只起一主两从
#   lab_compose --profile "*" down -v  全清
lab_compose() {
  docker compose --project-directory "$LAB_ROOT" -f "$LAB_ROOT/compose.yml" "$@"
}

# 实验目录里某个容器是否在跑
lab_any_running() {
  local c
  for c in $LAB_CONTAINERS; do is_running "$c" && return 0; done
  return 1
}

lab_all_running() {
  local c
  for c in $LAB_CONTAINERS; do is_running "$c" || return 1; done
  return 0
}

# 依赖顺序：先保证镜像，再起本实验自己的容器。每个实验只碰自己的目录。
lab_ensure() {
  local var port
  for var in $(printf '%s' "$LAB_PORTS" | tr ' ' '\n' | cut -d: -f1); do
    [ -n "$var" ] || continue
    need_port "$(lab_port "$var")" "$var" "use $LAB_NB"
  done
  ensure_image
  if lab_all_running; then
    note "$LAB_NB $LAB_NAME 的容器都在跑，直接复用（不重新初始化）"
    return 0
  fi
  if lab_any_running; then
    say "有容器停着，补齐（已有的不动）"
  else
    say "起 $LAB_NB $LAB_NAME 的环境（docker compose up -d，首次要初始化）"
  fi
  lab_compose --profile "$LAB_PROFILE" up -d \
    || die "容器起不来。看日志：docker compose -f compose.yml --profile $LAB_PROFILE logs --tail=40"
  local c
  for c in $LAB_CONTAINERS; do
    wait_healthy "$c" 300 || die "$c 300 秒仍未 healthy。看日志：
   docker compose -f compose.yml --profile $LAB_PROFILE logs --tail=40"
  done
}
