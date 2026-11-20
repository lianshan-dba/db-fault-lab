#!/usr/bin/env bash
# lab.sh 与各实验脚本共用的工具函数。
#
# 这里只放「跟具体实验无关」的东西：日志、docker 检查、镜像准备、等健康、打印连接信息。
# 任何跟 05 有关的知识（tmpfs、慢日志、filler.bin）都不许出现在这个文件里 ——
# 一旦出现，下一个实验就得靠改公共库来实现，解耦就白做了。

IMAGE=${MYSQL_IMAGE:-mysql:8.0}
IMG_REPO=${IMAGE%%:*}
IMG_TAG=${IMAGE##*:}

# 国内直连 Docker Hub 经常超时，按顺序试这些加速地址
MIRRORS=${MIRRORS:-"docker.m.daocloud.io docker.1panel.live dockerproxy.net"}

# 首选源：作者的国内公共镜像（阿里云杭州）。国内拉约 10 秒。
# 失效会自动回退，不影响使用。想换自己的仓库：
#   IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/你的命名空间 ./lab.sh up
IMAGE_MIRROR=${IMAGE_MIRROR-registry.cn-hangzhou.aliyuncs.com/lianshan-dba}
[ "$IMAGE_MIRROR" = "none" ] && IMAGE_MIRROR=""

LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf '\n!!  %s\n' "$*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "本机没有 docker。
   macOS：装 Docker Desktop，或者 brew install colima docker && colima start
   Linux：curl -fsSL https://get.docker.com | sh"
  docker info >/dev/null 2>&1 || die "docker 装了但没在运行（Docker Desktop 没开，或 colima 没 start）。"
  docker compose version >/dev/null 2>&1 || die "缺 docker compose v2。docker-compose 1.x 的语法不兼容，请升级。"
}

# 只探端口，不装 nc：bash 自带 /dev/tcp
port_busy() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) >/dev/null 2>&1; }

# 端口被占，但占的人就是我们 lab 自己的容器（反复 use / reset 时会这样），不算冲突
port_is_ours() {
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "^dfl-[^ ]* .*:$1->"
}

need_port() { # $1=端口 $2=变量名 $3=提示命令
  port_busy "$1" || return 0
  port_is_ours "$1" && return 0
  die "宿主端口 $1 已被占用（不是本 lab 的容器）。
   换个端口重来，例如：$2=$(( $1 + 10000 )) ./lab.sh $3"
}

# 镜像全机器只备一次。命中本地镜像直接返回，绝不重复拉。
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

   注意：实验用的数据全在容器里，镜像只是运行环境，换版本不影响实验结论。
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

is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
exists()     { docker inspect "$1" >/dev/null 2>&1; }

# 注意：lab_compose 定义在 lib/meta.sh —— 它要用 LAB_ROOT，而且跟「按 profile 起哪套容器」
# 绑在一起。公共库这里只管跟实验无关的东西。

# 实验一跑完，人的第一反应是「我要登进去自己看」。
# 不给这条信息，他就只能去翻 compose 文件找密码，或者干脆跳过动手。
print_conn() { # $1=描述 $2=容器名 $3=宿主端口
  printf '\n==> 连进去（%s）：用户 root  密码 rootpass  库 demo\n' "$1"
  cat <<EOF
    ① 容器内的客户端（本机没装 mysql 也能用，推荐先用这条）
         docker exec -it $2 mysql -uroot -prootpass demo

    ② 宿主机上的客户端（装了 mysql-client 才行）
         mysql -h127.0.0.1 -P$3 -uroot -prootpass demo

    ③ GUI（Navicat / DBeaver / DataGrip / TablePlus）
         主机 127.0.0.1   端口 $3   用户 root   密码 rootpass   库 demo

    注意：①②里看到 @@port 都是 3306，那是容器里的端口；从你机器连要写 $3。
    只绑 127.0.0.1，别的机器连不进来。随时重看：./lab.sh conn
EOF
}
