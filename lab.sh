#!/usr/bin/env bash
# db-fault-lab 唯一入口 —— 一个调度器，不含任何实验知识。
#
#   ./lab.sh list         有哪些实验
#   ./lab.sh up           备镜像（全机器只拉一次）
#   ./lab.sh use 05       起 05 自己的环境 + 注入故障
#   ./lab.sh reset 05     原地复原 05（不重建容器）
#   ./lab.sh status       哪些实验在跑、现在是什么状态
#   ./lab.sh conn         连进去的账号密码端口
#   ./lab.sh down / clean 停掉 / 删掉
#
# 实验全部登记在 labs/<编号>-<名字>/，每个目录自带 compose.yml、inject.sh、reset.sh。
# 这个脚本只负责「找目录 → 起容器 → 调脚本」，所以加 06 不用改这里一行。
#
# 端口用 133xx，避开本机可能已经占着的 3306/3307/3308。改端口：
#   DISK_FULL_PORT=23309 ./lab.sh use 05
#
# 不用 set -e：每一步失败时要能打印人话，而不是直接退出留下半个环境。
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. lib/common.sh
. lib/meta.sh

usage() {
  cat <<'EOF'
db-fault-lab：在本机复现 MySQL 故障，一条命令。

  ./lab.sh list          有哪些实验（编号 / 目录 / 标题）
  ./lab.sh doctor        环境自检（docker / compose / 端口 / 镜像 / 内存）
  ./lab.sh up            备镜像（全机器只拉这一次，之后一直复用）
  ./lab.sh up 05         备镜像 + 只把 05 的环境起起来（不注入）
  ./lab.sh use 05        起 05 的环境 + 注入故障
  ./lab.sh use 05 fix    自己试过之后再看处置动作（对答案，要有 fix.sh 的实验才有）
  ./lab.sh reset 05      原地复原，接着练下一轮（reset all 全复原）
  ./lab.sh status        哪些实验在跑、各自什么状态
  ./lab.sh conn          打印连接信息（用户名 / 密码 / 端口 / 登录命令）
  ./lab.sh down [05]     停掉容器但留着数据，下次 up 很快（不给编号 = 全部）
  ./lab.sh clean [05]    删掉容器与数据卷，下次从头来（镜像不删）

每个实验是一个自包含的目录：labs/<编号>-<名字>/
  compose.yml   这个实验自己的容器，project name 是 dfl-<编号>
  meta          编号、标题、端口、容器名、连接信息
  inject.sh     注入故障（会打印命令和真实报错）
  reset.sh      原地复原（不重建容器）
  fix.sh        可选，处置演示
  dirty.sh      可选，返回 0 表示「现场还在」
  status.sh     可选，额外状态（比如 df、复制状态）

实验之间没有任何共享容器，可以同时开着。
登录信息统一 root / rootpass，实验库 demo；复制账号 repl / replpass。

镜像默认从作者的国内公共镜像拉（阿里云杭州，约 10 秒）：
  registry.cn-hangzhou.aliyuncs.com/lianshan-dba/mysql:8.0
失效会自动回退官方源和公共加速站。想换自己的仓库：
  IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up
跳过它直接走官方源：
  IMAGE_MIRROR=none ./lab.sh up
EOF
}

# ---------------- 清单 ----------------

do_list() {
  printf '\n实验清单（容器都定义在同一个 compose.yml 里，按 profile 分组，互不干扰）：\n\n'
  labs_list | awk -F'\t' '{
    printf "  %s  %-20s %s\n", $1, $2, $3
    if ($4 != "") printf "      %s\n", $4
  }'
  printf '\n看某一篇的复盘：docs/<编号>-*.md\n起一个来练：./lab.sh use 05\n\n'
}

# ---------------- 连进去 ----------------

# meta 里的 CONN 是「描述|服务名|端口变量|容器名」用分号隔开。
# 只打印在跑的那些，免得给出一堆连不上的端口。
# 第一个给完整三种连法，后面的压成一行 —— 一主两从打三遍完整说明，屏幕就没法看了。
CONN_PRINTED=0      # 全局只让第一个实例打完整说明，其余压成一行
print_lab_conn() {
  local item desc svc pvar cname port any=0
  local IFS=';'
  for item in $LAB_CONN; do
    IFS='|' read -r desc svc pvar cname <<< "$item"
    IFS=';'
    is_running "$cname" || continue
    port=$(lab_port "$pvar")
    if [ "$CONN_PRINTED" -eq 0 ]; then
      print_conn "$desc" "$cname" "$port"
      CONN_PRINTED=1
    else
      printf '\n==> 连进去（%s）：容器内 docker exec -it %s mysql -uroot -prootpass demo ；宿主机 127.0.0.1:%s\n' \
        "$desc" "$cname" "$port"
    fi
    any=1
  done
  unset IFS
  if [ "$any" -eq 0 ]; then
    printf '\n==> %s 的容器没在跑。起环境：./lab.sh use %s\n' "$LAB_NB" "$LAB_NB"
  fi
}

do_conn() {
  need_docker
  CONN_PRINTED=0
  local any=0 nb dir
  while IFS=$'\t' read -r nb dir _ <&3; do
    lab_find "$nb"; lab_load
    lab_any_running || continue
    print_lab_conn
    any=1
  done 3< <(labs_list)
  if [ "$any" -eq 0 ]; then
    printf '\n==> 现在没有任何 lab 容器在跑。\n'
    printf '    先起一个：./lab.sh use 05（或 ./lab.sh list 看有哪些实验）\n'
    printf '    固定账号：root / rootpass，实验库 demo，复制账号 repl / replpass\n\n'
  fi
}

# ---------------- 状态 ----------------

do_status() {
  need_docker
  local nb dir title c state any=0
  while IFS=$'\t' read -r nb dir title _ <&3; do
    lab_find "$nb"; lab_load
    any=1
    if lab_any_running; then
      printf '\n==> %s %s（运行中）\n' "$LAB_NB" "$LAB_TITLE"
    else
      printf '\n==> %s %s（没在跑）\n' "$LAB_NB" "$LAB_TITLE"
      continue
    fi
    for c in $LAB_CONTAINERS; do
      if is_running "$c"; then
        state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)
        printf '    %-20s 运行中  健康 %s\n' "$c" "$state"
      elif exists "$c"; then
        printf '    %-20s 已停止\n' "$c"
      else
        printf '    %-20s 不存在\n' "$c"
      fi
    done
    # 实验自己的状态脚本（可选）：df 剩多少、复制通不通，只有实验自己知道怎么看
    if [ -x "$LAB_DIR/status.sh" ]; then
      "$LAB_DIR/status.sh" 2>/dev/null | sed 's/^/    /' || true
    fi
  done 3< <(labs_list)
  [ "$any" -eq 0 ] && printf '\nlabs/ 里还没有任何实验。\n'
  printf '\n'
}

# ---------------- 起 / 用 / 复原 ----------------

do_up() {
  need_docker
  CONN_PRINTED=0
  if [ -n "${1:-}" ]; then
    lab_find "$1"; lab_load
    lab_ensure
    printf '\n'
    note "环境起好了，还没注入故障。注入：./lab.sh use $LAB_NB"
    print_lab_conn
    printf '\n'
    return 0
  fi
  ensure_image
  printf '\n'
  note "镜像备好了。各实验自己起自己的容器，用的时候才起："
  note "  ./lab.sh use 05      磁盘写满 + 慢日志句柄未释放"
  note "  ./lab.sh use 01      主库被 kill -9"
  note "  ./lab.sh use 02      元数据锁阻塞"
  note "  ./lab.sh list        看全部"
  printf '\n'
}

do_use() {
  local nb=$1 mode=${2:-inject}
  CONN_PRINTED=0
  lab_find "$nb"; lab_load
  need_docker
  lab_ensure

  if [ "$mode" = "fix" ]; then
    [ -x "$LAB_DIR/fix.sh" ] || die "$LAB_NB 没有处置演示（fix.sh）。这个实验的答案在 docs/ 里。"
    if [ -x "$LAB_DIR/dirty.sh" ] && ! "$LAB_DIR/dirty.sh"; then
      die "环境里现在是干净的，没有可处置的现场。先切过去：./lab.sh use $LAB_NB"
    fi
    say "处置演示（对答案）：$LAB_NB $LAB_TITLE"
    "$LAB_DIR/fix.sh"
    print_lab_conn
    printf '\n'
    note "复原重练：./lab.sh reset $LAB_NB && ./lab.sh use $LAB_NB"
    printf '\n'
    return 0
  fi

  # 同一个环境反复练的关键：上次的现场先原地抹掉，而不是 docker rm 重来。
  # 怎么判断「现场还在」只有实验自己知道，所以问实验目录里的 dirty.sh。
  if [ -x "$LAB_DIR/dirty.sh" ] && "$LAB_DIR/dirty.sh"; then
    say "环境里还留着上次 $LAB_NB 的现场，先原地复原（不重建容器）"
    "$LAB_DIR/reset.sh" >/dev/null || die "复原失败，单独跑一遍看输出：$LAB_DIR/reset.sh"
  fi

  say "注入：$LAB_NB $LAB_TITLE"
  "$LAB_DIR/inject.sh"
  print_lab_conn
  printf '\n'
  [ -x "$LAB_DIR/fix.sh" ] && note "自己试完再看处置演示：./lab.sh use $LAB_NB fix"
  note "练完复原：./lab.sh reset $LAB_NB      换实验：./lab.sh list"
  printf '\n'
}

do_reset() {
  need_docker
  local target=${1:-all} nb dir title
  if [ "$target" = "all" ]; then
    while IFS=$'\t' read -r nb dir _ <&3; do
      lab_find "$nb"; lab_load
      lab_any_running || continue
      say "复原 $LAB_NB $LAB_TITLE"
      "$LAB_DIR/reset.sh" || warn "$LAB_NB 复原失败，单独跑：$LAB_DIR/reset.sh"
    done 3< <(labs_list)
    printf '\n'
    note "全部复原完成。切下一个：./lab.sh use 01 / use 02 / use 05"
    printf '\n'
    return 0
  fi

  lab_find "$target"; lab_load
  if ! lab_any_running; then
    note "$LAB_NB 的容器没在跑，没什么可复原的。要起环境：./lab.sh use $LAB_NB"
    return 0
  fi
  [ -x "$LAB_DIR/reset.sh" ] || die "$LAB_NB 没有 reset.sh，只能 ./lab.sh clean $LAB_NB 重建"
  say "复原 $LAB_NB $LAB_TITLE"
  "$LAB_DIR/reset.sh"
  printf '\n'
  note "复原完成。再练一轮：./lab.sh use $LAB_NB"
  printf '\n'
}

# ---------------- 停 / 清 ----------------

do_down() {
  need_docker
  local target=${1:-all} nb dir
  if [ "$target" = "all" ]; then
    # --profile "*" 是「所有 profile 一起」，比逐个 stop 更干净
    say "停掉全部实验的容器（数据留着）"
    lab_compose --profile "*" stop
    note "已停。彻底删掉用 ./lab.sh clean；下次 ./lab.sh use XX 几秒就回来"
    return 0
  fi
  lab_find "$target"; lab_load
  say "停掉 $LAB_NB $LAB_TITLE（数据留着）"
  lab_compose --profile "$LAB_PROFILE" stop
}

do_clean() {
  need_docker
  local target=${1:-all} nb dir
  if [ "$target" = "all" ]; then
    say "删掉全部实验的容器与数据卷"
    lab_compose --profile "*" down --remove-orphans -v
    note "已清理。镜像还在，下次不会重新拉。"
    return 0
  fi
  lab_find "$target"; lab_load
  say "删掉 $LAB_NB $LAB_TITLE 的容器与数据卷"
  lab_compose --profile "$LAB_PROFILE" down --remove-orphans -v
  note "已清理。下次 ./lab.sh use $LAB_NB 是全新环境（镜像还在，不会重新拉）。"
}

# ---------------- 自检 ----------------

do_doctor() {
  need_docker
  note "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  note "compose: $(docker compose version --short 2>/dev/null)"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    note "镜像 $IMAGE: 已就绪"
  else
    note "镜像 $IMAGE: 未拉取，跑实验时会自动拉（首选源：${IMAGE_MIRROR:-官方 Docker Hub}）"
  fi
  local nb dir pvar port
  while IFS=$'\t' read -r nb dir _ <&3; do
    lab_find "$nb"; lab_load
    for pvar in $(printf '%s' "$LAB_PORTS" | tr ' ' '\n' | cut -d: -f1); do
      [ -n "$pvar" ] || continue
      port=$(lab_port "$pvar")
      if port_busy "$port" && ! port_is_ours "$port"; then
        warn "$LAB_NB 的端口 $port: 被别的程序占用（改：$pvar=$((port + 10000)) ./lab.sh use $LAB_NB）"
      else
        note "$LAB_NB 的端口 $port: 空闲"
      fi
    done
  done 3< <(labs_list)
  note "内存建议 ≥ 4G（同时开 01 的一主两从和 05 会用到 2G 上下）"
  if command -v free >/dev/null 2>&1; then note "本机内存: $(free -g | awk 'NR==2{print $2"G"}')"; fi
  printf '\n自检完。没问题就跑：./lab.sh use 05\n\n'
}

# ---------------- 入口 ----------------

case "${1:-}" in
  ""|-h|--help|help)   usage ;;
  list|ls|实验)        do_list ;;
  doctor)              do_doctor ;;
  up|start)            do_up "${2:-}" ;;
  down|stop)           do_down "${2:-all}" ;;
  status|ps)           do_status ;;
  conn|连接|login)     do_conn ;;
  clean)               do_clean "${2:-all}" ;;
  reset)               do_reset "${2:-all}" ;;
  use)
    [ -n "${2:-}" ] || die "用法：./lab.sh use <编号> [fix]（不知道编号：./lab.sh list）"
    do_use "$2" "${3:-inject}"
    ;;
  *)
    # 兼容老写法：./lab.sh 05 [fix] 等价于 ./lab.sh use 05 [fix]
    if [ -d "$LABS_DIR" ]; then
      for d in "$LABS_DIR"/*/; do
        [ "$(meta_get "$d/meta" NB 2>/dev/null)" = "$1" ] && { do_use "$1" "${2:-inject}"; exit $?; }
      done
    fi
    die "不认识的参数：$1（不带参数看用法）"
    ;;
esac
