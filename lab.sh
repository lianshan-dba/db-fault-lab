#!/usr/bin/env bash
# db-fault-lab 一条命令复现入口
#
#   ./lab.sh              看有哪些实验
#   ./lab.sh up           把环境起起来（拉镜像只发生这一次，之后一直复用）
#   ./lab.sh use 05       在当前环境里切到 05 的故障（不重建容器）
#   ./lab.sh reset 05     把 05 原地复原，接着练下一个（不重建容器）
#   ./lab.sh status       现在环境里是哪种故障、占了多少盘
#   ./lab.sh clean        整套删掉（下次从头来）
#
# 环境是常驻的：镜像只拉一次，datadir 只初始化一次。切故障靠脚本，不靠重建。
#
# 端口默认用 133xx，避开你本机可能已经占着的 3306/3307/3308：
#   DISK_FULL_PORT=23309 ./lab.sh use 05
#
# 不用 set -e：每一步失败时要能打印人话，而不是直接退出留下半个环境。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMAGE=${MYSQL_IMAGE:-mysql:8.0}
IMG_REPO=${IMAGE%%:*}          # mysql
IMG_TAG=${IMAGE##*:}           # 8.0
# 国内直连 Docker Hub 经常超时，按顺序试这些加速地址
MIRRORS=${MIRRORS:-"docker.m.daocloud.io docker.1panel.live dockerproxy.net"}
# 首选源：作者的国内公共镜像（阿里云杭州）。国内拉约 10 秒，比 Docker Hub 快得多。
# 它失效了会自动回退，不影响使用。想换成自己的仓库：
#   IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up
# 想跳过它、直接走官方源：
#   IMAGE_MIRROR=none ./lab.sh up
IMAGE_MIRROR=${IMAGE_MIRROR-registry.cn-hangzhou.aliyuncs.com/lianshan-dba}
[ "$IMAGE_MIRROR" = "none" ] && IMAGE_MIRROR=""

P_MASTER=${MASTER_PORT:-13306}
P_SLAVE1=${SLAVE1_PORT:-13307}
P_SLAVE2=${SLAVE2_PORT:-13308}
P_DISK=${DISK_FULL_PORT:-13309}

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '\n!!  %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
db-fault-lab：在本机复现 MySQL 故障，一条命令。

  ./lab.sh up            起常驻环境（镜像只拉这一次，之后一直复用）
  ./lab.sh status        现在环境里是什么状态（容器 / 盘 / 复制）
  ./lab.sh use 05        切到 05：磁盘写满 + 慢日志句柄未释放
  ./lab.sh use 01        切到 01：主库被 kill -9（会顺带建好一主两从）
  ./lab.sh use 02        切到 02：元数据锁阻塞
  ./lab.sh use 05 fix    自己试过之后再看处置动作（对答案）
  ./lab.sh reset 05      原地复原，接着练下一个（或 reset all）
  ./lab.sh conn          打印连接信息（用户名 / 密码 / 端口 / 登录命令）
  ./lab.sh down          停掉容器但留着数据，下次 up 很快
  ./lab.sh clean         删掉容器与数据卷，下次从头来

环境是常驻的：镜像和 datadir 只准备一次，切故障靠脚本，不靠重建容器。
实验清单见 README.md，每篇复盘在 docs/。
登录信息统一是 root / rootpass，复制账号 repl / replpass，端口见 ./lab.sh conn。

镜像默认从作者的国内公共镜像拉（阿里云杭州，约 10 秒）：
  registry.cn-hangzhou.aliyuncs.com/lianshan-dba/mysql:8.0
它失效会自动回退官方源和公共加速站。想换自己的仓库：
  IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up
跳过它直接走官方源：
  IMAGE_MIRROR=none ./lab.sh up
EOF
}

# 只探端口，不装 nc：bash 自带 /dev/tcp
port_busy() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) >/dev/null 2>&1; }

# 端口被占，但占的人就是我们自己的容器（反复 use / reset 时会这样），不算冲突
port_is_ours() {
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "^dfl-[^ ]* .*:$1->"
}

need_port() {
  port_busy "$1" || return 0
  port_is_ours "$1" && return 0
  die "宿主端口 $1 已被占用（不是本 lab 的容器）。
   换个端口重来，例如：${2}=$(( $1 + 10000 )) ./lab.sh ${3}"
}

need_docker() {
  command -v docker >/dev/null 2>&1 || die "本机没有 docker。
   macOS：装 Docker Desktop，或者 brew install colima docker && colima start
   Linux：curl -fsSL https://get.docker.com | sh"
  docker info >/dev/null 2>&1 || die "docker 装了但没在运行（Docker Desktop 没开，或 colima 没 start）。"
  docker compose version >/dev/null 2>&1 || die "缺 docker compose v2。docker-compose 1.x 的语法不兼容，请升级。"
}

ensure_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    note "镜像已就绪：$IMAGE（不会重复拉）"
    return 0
  fi
  say "本地没有 $IMAGE，开始拉取（约 600MB，全机器只此一次）"

  # 1) 首选源（默认是作者的阿里云公共镜像）
  if [ -n "$IMAGE_MIRROR" ]; then
    note "优先用指定仓库：$IMAGE_MIRROR/$IMG_REPO:$IMG_TAG"
    if docker pull "$IMAGE_MIRROR/$IMG_REPO:$IMG_TAG"; then
      docker tag "$IMAGE_MIRROR/$IMG_REPO:$IMG_TAG" "$IMAGE"
      note "已从 $IMAGE_MIRROR 拉到，并打成 $IMAGE"
      return 0
    fi
    warn "这个仓库用不了（未公开 / 已删除 / 需登录），回退下一个源，不影响实验"
  fi

  # 2) 官方源
  if docker pull "$IMAGE"; then
    note "拉取完成"
    return 0
  fi

  # 3) 公共加速站
  say "官方源失败，换公共加速源"
  local m
  for m in $MIRRORS; do
    note "尝试 $m ..."
    if docker pull "$m/library/$IMG_REPO:$IMG_TAG"; then
      docker tag "$m/library/$IMG_REPO:$IMG_TAG" "$IMAGE"
      note "已从 $m 拉到，并打成 $IMAGE"
      return 0
    fi
  done

  cat >&2 <<EOF

!! 全部都拉不下来。四个办法，按顺序试：

   1) 用你自己的国内仓库（最快，一次推好长期可用）
        IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up
      怎么把镜像放上去：./tools/push-mirror.sh registry.cn-hangzhou.aliyuncs.com/你的命名空间

   2) 配加速器（一次配好永久有效）
      Docker Desktop → Settings → Docker Engine，在 json 里加：
        "registry-mirrors": ["https://docker.m.daocloud.io"]

   3) 借一台有网的机器搬过来（镜像只有 600MB，U 盘都行）
        docker save $IMAGE | gzip > mysql80.tar.gz     # 有网的机器
        docker load < mysql80.tar.gz                    # 你这台

   4) 自己指定加速地址
        MIRRORS=docker.你的源.com ./lab.sh up

   注意：lab 用的数据全在容器里，镜像只是运行环境，换版本不影响实验结论。
EOF
  exit 1
}

wait_healthy() { # $1=容器名 $2=超时秒数
  local c=$1 limit=${2:-180} i=0
  while [ "$i" -lt "$limit" ]; do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = "healthy" ]; then
      return 0
    fi
    sleep 2
    i=$((i + 2))
    [ $((i % 20)) -eq 0 ] && note "等待 $c 就绪 ... ${i}s"
  done
  return 1
}

compose() { ( cd mysql && docker compose "$@" ); }

is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
exists()     { docker inspect "$1" >/dev/null 2>&1; }

# 05 的 datadir 是 tmpfs：容器在，现场就在。用慢日志大小判断「是否已经注入过」。
dirty_05() {
  local sz
  sz=$(compose exec -T mysql-disk-full stat -c %s /var/lib/mysql/slow.log 2>/dev/null | tr -d '\r')
  [ -n "${sz:-}" ] && [ "$sz" -gt 52428800 ]   # > 50M 说明灌过
}

# 实验一跑完，人的第一反应是「我要登进去自己看」。
# 不给这条信息，他就只能去翻 docker-compose.yml 找密码，或者干脆跳过动手。
print_conn() { # $1=容器名 $2=服务名 $3=宿主端口 $4=说明
  local c=$1 svc=$2 port=$3 desc=$4
  printf '\n==> 连进去（%s）：用户 root  密码 rootpass  库 demo\n' "$desc"
  cat <<EOF
    ① 容器内的客户端（本机没装 mysql 也能用，推荐先用这条）
         docker compose -f mysql/docker-compose.yml exec $svc mysql -uroot -prootpass demo

    ② 宿主机上的客户端（装了 mysql-client 才行）
         mysql -h127.0.0.1 -P$port -uroot -prootpass demo

    ③ GUI（Navicat / DBeaver / DataGrip / TablePlus）
         主机 127.0.0.1   端口 $port   用户 root   密码 rootpass   库 demo

    注意：①②里看到 @@port 都是 3306，那是容器里的端口；从你机器连要写 $port。
    只绑 127.0.0.1，别的机器连不进来。随时重看：./lab.sh conn
EOF
}

# ---------------- 把环境准备好（已在跑就直接复用） ----------------

# 05 用的独立实例：768M tmpfs，盘满只发生在容器内存里
ensure_05() {
  need_port "$P_DISK" DISK_FULL_PORT "use 05"
  ensure_image
  if is_running dfl-disk-full; then
    note "mysql-disk-full 已在跑，直接复用（不重新初始化）"
    return 0
  fi
  if exists dfl-disk-full; then
    say "mysql-disk-full 是停着的，拉起来（tmpfs 会重建，等于干净环境，约 30 秒）"
  else
    say "起独立实例 mysql-disk-full（datadir 是 768M 的 tmpfs，盘满只发生在容器里）"
  fi
  compose up -d mysql-disk-full || die "容器起不来。看日志：cd mysql && docker compose logs mysql-disk-full"
  wait_healthy dfl-disk-full 240 || die "240 秒仍未 healthy。看日志：cd mysql && docker compose logs --tail=40 mysql-disk-full"
}

# 01 / 02 用的一主两从
ensure_repl() {
  need_port "$P_MASTER" MASTER_PORT 01
  need_port "$P_SLAVE1" SLAVE1_PORT 01
  need_port "$P_SLAVE2" SLAVE2_PORT 01
  ensure_image
  local started=0 c
  for c in dfl-master dfl-slave-1 dfl-slave-2; do
    is_running "$c" || started=1
  done
  if [ "$started" -eq 1 ]; then
    say "起一主两从（首次初始化约 60 秒，之后一直复用）"
    compose up -d || die "启动失败。看日志：cd mysql && docker compose logs --tail=40"
  else
    note "一主两从已在跑，直接复用"
  fi
  for c in dfl-master dfl-slave-1 dfl-slave-2; do
    wait_healthy "$c" 300 || die "$c 没起来。看日志：cd mysql && docker compose logs --tail=40 $c"
  done
}

# ---------------- 各实验 ----------------

use_05() {
  local mode=${1:-inject}
  ensure_05
  if [ "$mode" = "fix" ]; then
    if ! dirty_05; then
      die "环境里现在是干净的，没有可处置的现场。先切过去：./lab.sh use 05"
    fi
    say "处置演示（对答案）"
    ./mysql/inject/disk-full-fix.sh
    cat <<EOF

----------------------------------------------------------------
答案看完了。真正要留下的是你自己那句话：当时你以为是什么、看到什么才改主意。
把它写成 docs/05 的「排查过程」，然后 ./lab.sh reset 05 复原（不用重建容器）。
----------------------------------------------------------------
EOF
    print_conn dfl-disk-full mysql-disk-full "$P_DISK" "05 的独立实例 mysql-disk-full"
    return 0
  fi

  # 同一个环境反复练的关键：上次的现场先原地抹掉，而不是 docker rm 重来
  if dirty_05; then
    say "环境里还留着上次 05 的现场，先原地复原（一两秒，不重建容器）"
    ./mysql/inject/disk-full-reset.sh >/dev/null || die "复原失败，单独跑一遍看输出：./mysql/inject/disk-full-reset.sh"
  fi

  say "注入故障"
  ./mysql/inject/disk-full.sh
  cat <<EOF

----------------------------------------------------------------
上面那几个问题就是这次要练的。自己动手试完（先写预测，再去 rm），
再看处置演示：./lab.sh use 05 fix
练完复原、换下一个故障：./lab.sh reset 05 && ./lab.sh use 01
----------------------------------------------------------------
EOF
  print_conn dfl-disk-full mysql-disk-full "$P_DISK" "05 的独立实例 mysql-disk-full"
}

use_01() {
  ensure_repl
  say "建立复制关系（GTID 自动定位；已经在复制就重建一遍，几秒）"
  ./mysql/scripts/init-replica.sh
  say "注入：kill -9 主库"
  ./mysql/inject/kill-master.sh
  print_conn dfl-master mysql-master "$P_MASTER" "主库 mysql-master"
  note "两个从库一样能登：端口 $P_SLAVE1 / $P_SLAVE2，容器 dfl-slave-1 / dfl-slave-2，用户 root / rootpass"
  note "复制账号是 repl / replpass（只给复制用，不是给你登的）"
}

use_02() {
  ensure_repl
  note "主库 healthy（表 t_pk 有 10 万行，初始化时已灌好）"
  say "注入：元数据锁阻塞"
  ./mysql/inject/mdl-block.sh
  print_conn dfl-master mysql-master "$P_MASTER" "主库 mysql-master"
  note "被阻塞的会话要另开一个窗口才看得到，别在同一个会话里等"
  note "复原：./lab.sh reset 02（杀掉挂住的会话，把加上的列撤掉）"
}

# ---------------- 复原 / 状态 / 起停 ----------------

reset_one() { # $1=实验号
  case "$1" in
    05)
      if ! is_running dfl-disk-full; then note "mysql-disk-full 没在跑，没什么可复原的"; return 0; fi
      ./mysql/inject/disk-full-reset.sh
      ;;
    01|02)
      local c
      for c in dfl-master dfl-slave-1 dfl-slave-2; do
        is_running "$c" || { note "$c 没在跑，跳过"; return 0; }
      done
      if [ "$1" = "02" ]; then
        ./mysql/inject/mdl-reset.sh
      else
        say "复原 01：等主库起来，重新接上复制"
        wait_healthy dfl-master 300 || die "主库没起来，看日志：cd mysql && docker compose logs --tail=40 mysql-master"
        ./mysql/scripts/init-replica.sh | tail -8
      fi
      ;;
    *) die "不认识的实验号：$1（有 01 / 02 / 05）" ;;
  esac
}

do_reset() {
  need_docker
  case "${1:-all}" in
    all)
      reset_one 05
      reset_one 01
      ;;
    *) reset_one "$1" ;;
  esac
  printf '\n'
  note "复原完成。切下一个：./lab.sh use 01 / use 02 / use 05"
}

do_status() {
  need_docker
  local c rs
  for c in dfl-master dfl-slave-1 dfl-slave-2 dfl-disk-full; do
    if is_running "$c"; then
      printf '    %-14s 运行中  健康 %s\n' "$c" "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null)"
    elif exists "$c"; then
      printf '    %-14s 已停止\n' "$c"
    else
      printf '    %-14s 不存在\n' "$c"
    fi
  done
  if is_running dfl-disk-full; then
    printf '\n==> 05 的盘（tmpfs 768M）\n'
    compose exec -T mysql-disk-full sh -c 'df -h /var/lib/mysql | tail -1; du -sh /var/lib/mysql; ls -lh /var/lib/mysql/slow.log /var/lib/mysql/filler.bin 2>/dev/null' \
      | sed 's/^/    /' || true
    if dirty_05; then note "状态：已注入（练完用 ./lab.sh reset 05 复原）"; else note "状态：干净"; fi
  fi
  if is_running dfl-slave-1; then
    printf '\n==> 复制状态\n'
    rs=$(compose exec -T mysql-slave-1 mysql -uroot -prootpass -e "SHOW REPLICA STATUS\G" 2>/dev/null \
      | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source')
    if [ -z "${rs:-}" ]; then
      note "还没建复制关系（./lab.sh use 01 会建）"
    else
      printf '%s\n' "$rs" | sed 's/^/    /'
    fi
  fi
  printf '\n'
}

do_up() {
  need_docker
  ensure_image
  say "把环境起起来（镜像和 datadir 只准备这一次，之后一直复用）"
  ensure_repl
  ensure_05
  do_status
  cat <<'EOF'
环境常驻了，接下来不用再等初始化：
    ./lab.sh use 05      磁盘写满 + 慢日志句柄未释放
    ./lab.sh use 01      主库被 kill -9
    ./lab.sh use 02      元数据锁阻塞
    ./lab.sh reset 05    原地复原，接着练下一个
    ./lab.sh status      随时看现在是什么状态
EOF
}

do_down() {
  need_docker
  say "停掉容器（数据留着，下次 ./lab.sh up 几秒就回来）"
  compose --profile disk-full stop
  note "已停。彻底删掉用 ./lab.sh clean"
}

do_doctor() {
  need_docker
  note "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  note "compose: $(docker compose version --short 2>/dev/null)"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    note "镜像 $IMAGE: 已就绪"
  else
    note "镜像 $IMAGE: 未拉取，跑实验时会自动拉（首选源：${IMAGE_MIRROR:-官方 Docker Hub}）"
  fi
  local p
  for p in "$P_MASTER" "$P_SLAVE1" "$P_SLAVE2" "$P_DISK"; do
    if port_busy "$p"; then warn "端口 $p: 被占用"; else note "端口 $p: 空闲"; fi
  done
  note "内存建议 ≥ 4G（一主两从 + 05 实例同时跑）"
  if command -v free >/dev/null 2>&1; then note "本机内存: $(free -g | awk 'NR==2{print $2"G"}')"; fi
  printf '\n自检完。没问题就跑：./lab.sh up\n'
}

do_clean() {
  need_docker
  say "停掉并删除所有容器与数据卷"
  compose --profile disk-full down --remove-orphans -v
  note "已清理。下次 ./lab.sh up 是全新环境（镜像还在，不会重新拉）。"
}

do_conn() {
  need_docker
  local any=0
  if is_running dfl-master; then
    print_conn dfl-master mysql-master "$P_MASTER" "主库 mysql-master"; any=1
  fi
  if is_running dfl-slave-1; then
    print_conn dfl-slave-1 mysql-slave-1 "$P_SLAVE1" "从库 mysql-slave-1"; any=1
  fi
  if is_running dfl-slave-2; then
    print_conn dfl-slave-2 mysql-slave-2 "$P_SLAVE2" "从库 mysql-slave-2"; any=1
  fi
  if is_running dfl-disk-full; then
    print_conn dfl-disk-full mysql-disk-full "$P_DISK" "05 的独立实例 mysql-disk-full"; any=1
  fi
  if [ "$any" -eq 0 ]; then
    printf '\n==> 现在没有 lab 容器在跑。先起环境：./lab.sh up\n'
    printf '    固定账号：root / rootpass，实验库 demo，复制账号 repl / replpass\n\n'
  fi
}

MODE=inject
case "${1:-}" in
  ""|list|-h|--help|help) usage ;;
  doctor)                 do_doctor ;;
  up|start)               do_up ;;
  down|stop)              do_down ;;
  status|ps)              do_status ;;
  conn|连接|login)        do_conn ;;
  clean)                  do_clean ;;
  reset)                  do_reset "${2:-all}" ;;
  use)
    EXP=${2:-}; [ -z "$EXP" ] && die "用法：./lab.sh use 05 | use 01 | use 02"
    need_docker
    case "$EXP" in
      05) use_05 "${3:-inject}" ;;
      01) use_01 ;;
      02) use_02 ;;
      *)  die "不认识的实验号：$EXP（有 01 / 02 / 05）" ;;
    esac
    ;;
  01|02|05)               # 兼容老写法：./lab.sh 05 [fix] 等价于 ./lab.sh use 05 [fix]
    EXP=$1
    MODE=${2:-inject}
    [ "$MODE" = "fix" ] && [ "$EXP" != "05" ] && die "只有 05 有 fix 演示（其他实验的答案在 docs/ 里）"
    need_docker
    case "$EXP" in
      05) use_05 "$MODE" ;;
      01) use_01 ;;
      02) use_02 ;;
    esac
    ;;
  *) die "不认识的参数：$1（不带参数看用法）" ;;
esac
