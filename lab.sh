#!/usr/bin/env bash
# db-fault-lab 一条命令复现入口
#
#   ./lab.sh              看有哪些实验
#   ./lab.sh doctor       只做环境自检，不动容器
#   ./lab.sh 05           复现 05：自动备镜像 → 起实例 → 注入故障 → 打印该自己回答的问题
#   ./lab.sh 05 fix       自己试过之后再跑，对答案
#   ./lab.sh 01           同上，主库 kill -9（会顺带建好一主两从）
#   ./lab.sh 02           同上，元数据锁阻塞
#   ./lab.sh clean        清掉容器和卷
#
# 唯一的前置条件是有 docker（含 compose v2）。镜像第一次会自动拉，之后不再拉。
#
# 端口默认用 133xx，避开你本机可能已经占着的 3306/3307/3308：
#   DISK_FULL_PORT=23309 ./lab.sh 05
#
# 不用 set -e：每一步失败时要能打印人话，而不是直接退出留下半个环境。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMAGE=${MYSQL_IMAGE:-mysql:8.0}
# 国内直连 Docker Hub 经常超时，按顺序试这些加速地址
MIRRORS=${MIRRORS:-"docker.m.daocloud.io docker.1panel.live dockerproxy.net"}

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

  ./lab.sh doctor        环境自检（docker / compose / 端口 / 镜像）
  ./lab.sh 05            复现 05：磁盘写满 + 慢日志句柄未释放
  ./lab.sh 05 fix        自己试过之后再看处置动作（对答案用）
  ./lab.sh 01            复现 01：主库被 kill -9
  ./lab.sh 02            复现 02：元数据锁阻塞
  ./lab.sh clean         停掉并删除容器与数据卷

实验清单见 README.md，每篇复盘在 docs/。
EOF
}

# 只探端口，不装 nc：bash 自带 /dev/tcp
port_busy() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) >/dev/null 2>&1; }

# 端口被占，但占的人就是我们自己的容器（第二次跑 fix 时会这样），不算冲突
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
    note "镜像已就绪：$IMAGE"
    return 0
  fi
  say "本地没有 $IMAGE，开始拉取（约 600MB，只此一次）"
  if docker pull "$IMAGE"; then
    note "拉取完成"
    return 0
  fi

  say "官方源失败，换国内加速源"
  local m
  for m in $MIRRORS; do
    note "尝试 $m ..."
    if docker pull "$m/library/mysql:8.0"; then
      docker tag "$m/library/mysql:8.0" "$IMAGE"
      note "已从 $m 拉到，并打成 $IMAGE"
      return 0
    fi
  done

  cat >&2 <<EOF

!! 三条镜像都拉不下来。三个办法，按顺序试：

   1) 配加速器（最省事，一次配好永久有效）
      Docker Desktop → Settings → Docker Engine，在 json 里加：
        "registry-mirrors": ["https://docker.m.daocloud.io"]

   2) 借一台有网的机器搬过来（镜像只有 600MB，U 盘都行）
        docker save $IMAGE | gzip > mysql80.tar.gz     # 有网的机器
        docker load < mysql80.tar.gz                    # 你这台

   3) 自己指定加速地址
        MIRRORS=docker.你的源.com ./lab.sh ${EXP:-05}

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

# ---------------- 各实验 ----------------

run_05() {
  need_port "$P_DISK" DISK_FULL_PORT 05
  ensure_image
  say "起独立实例 mysql-disk-full（datadir 是 768M 的 tmpfs，盘满只发生在容器里）"
  compose up -d mysql-disk-full || die "容器起不来。看日志：cd mysql && docker compose logs mysql-disk-full"
  say "等实例初始化（首次约 30 秒）"
  wait_healthy dfl-disk-full 240 || die "240 秒仍未 healthy。看日志：cd mysql && docker compose logs --tail=40 mysql-disk-full"

  if [ "${MODE:-inject}" = "fix" ]; then
    say "处置演示（对答案）"
    ./mysql/inject/disk-full-fix.sh
    cat <<EOF

----------------------------------------------------------------
答案看完了。真正要留下的是你自己那句话：当时你以为是什么、看到什么才改主意。
把它写成 docs/05 的「排查过程」，然后 ./lab.sh clean。
----------------------------------------------------------------
EOF
    return 0
  fi

  say "注入故障"
  ./mysql/inject/disk-full.sh
  cat <<EOF

----------------------------------------------------------------
脚本到此为止，剩下的要你自己动手（现在别急着往下翻 docs/05）：

  1. df 100%、du 只有一半，差的那部分去哪了？去 /proc 里找证据。
     提示：mysqld 在容器里是 1 号进程，容器默认给你 root，读它的 fd 会被拒。
  2. 写下你的预测，再执行 rm 慢日志 —— df 会降吗？为什么？
  3. 不重启实例，把空间要回来。想清楚了再跑：./lab.sh 05 fix
  4. 三件事都能答之后，重置重练一遍：./lab.sh clean && ./lab.sh 05
----------------------------------------------------------------
EOF
}

run_01() {
  need_port "$P_MASTER" MASTER_PORT 01
  need_port "$P_SLAVE1" SLAVE1_PORT 01
  need_port "$P_SLAVE2" SLAVE2_PORT 01
  ensure_image
  say "起一主两从（首次初始化约 60 秒）"
  compose up -d || die "启动失败。看日志：cd mysql && docker compose logs --tail=40"
  for c in dfl-master dfl-slave-1 dfl-slave-2; do
    wait_healthy "$c" 300 || die "$c 没起来。看日志：cd mysql && docker compose logs --tail=40 $c"
    note "$c healthy"
  done
  say "建立复制关系（GTID 自动定位）"
  ./mysql/scripts/init-replica.sh
  say "注入：kill -9 主库"
  ./mysql/inject/kill-master.sh
}

run_02() {
  need_port "$P_MASTER" MASTER_PORT 02
  ensure_image
  say "起主库（02 用不到从库，只起一个，省内存）"
  compose up -d mysql-master || die "容器起不来。看日志：cd mysql && docker compose logs --tail=40 mysql-master"
  wait_healthy dfl-master 300 || die "主库没起来。看日志：cd mysql && docker compose logs --tail=40 mysql-master"
  note "主库 healthy（表 t_pk 有 10 万行，初始化时已灌好）"
  say "注入：元数据锁阻塞"
  ./mysql/inject/mdl-block.sh
}

do_doctor() {
  need_docker
  note "docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  note "compose: $(docker compose version --short 2>/dev/null)"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    note "镜像 $IMAGE: 已就绪"
  else
    warn "镜像 $IMAGE: 未拉取，首次跑实验会自动拉（约 600MB）"
  fi
  local p
  for p in "$P_MASTER" "$P_SLAVE1" "$P_SLAVE2" "$P_DISK"; do
    if port_busy "$p"; then warn "端口 $p: 被占用"; else note "端口 $p: 空闲"; fi
  done
  note "内存建议 ≥ 4G（一主两从同时跑）"
  if command -v free >/dev/null 2>&1; then note "本机内存: $(free -g | awk 'NR==2{print $2"G"}')"; fi
  printf '\n自检完。没问题就跑：./lab.sh 05\n'
}

do_clean() {
  need_docker
  say "停掉并删除所有容器与数据卷"
  compose --profile disk-full down --remove-orphans -v
  note "已清理。下次 ./lab.sh 05 是全新建环境。"
}

MODE=inject
case "${1:-}" in
  ""|list|-h|--help|help) usage ;;
  doctor)                 do_doctor ;;
  clean)                  do_clean ;;
  01|02|05)
    EXP=$1
    MODE=${2:-inject}
    [ "$MODE" = "fix" ] && [ "$EXP" != "05" ] && die "只有 05 有 fix 演示（其他实验的答案在 docs/ 里）"
    need_docker
    "run_$EXP"
    ;;
  *) die "不认识的参数：$1（不带参数看用法）" ;;
esac
