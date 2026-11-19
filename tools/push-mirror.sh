#!/usr/bin/env bash
# 把 lab 用的镜像镜像到你自己/公司的国内仓库（阿里云 ACR、harbor），让别人拉得快。
#
#   ./tools/push-mirror.sh registry.cn-hangzhou.aliyuncs.com/your-ns
#
# 推完以后，别人这样用（不用改任何文件）：
#   IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/your-ns ./lab.sh 05
# 为什么默认用 buildx imagetools create 而不是 docker push：
#   docker push 只能推「本机已有镜像」的那一个架构（在 x86 机器上就是 amd64）。
#   别人用 Apple Silicon 拉到 amd64 镜像会走 QEMU 模拟，又慢又容易出怪问题。
#   imagetools create 是把源仓库里的**多架构索引整体复制**过去，amd64/arm64 都在，
#   而且 digest 和官方索引一模一样 —— 这一点可以直接拿来核对。
#
# 阿里云 ACR 个人版注意三点：
#   1) 仓库要设成「公开」，否则别人拉会 401
#   2) docker login 用「仓库密码」（固定密码），不是阿里云账号密码
#   3) 有存储和流量额度
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FROM_LOCAL=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --from-local) FROM_LOCAL=1 ;;
    -h|--help) ARGS=("--help") ;;
    *) ARGS+=("$a") ;;
  esac
done

TARGET=${ARGS[0]:-}
IMAGE=${MYSQL_IMAGE:-mysql:8.0}
REPO=${IMAGE%%:*}
TAG=${IMAGE##*:}
# 源：优先官方索引；官方不可达时用 daocloud（它代理的就是官方索引，digest 一致）
SRC=${ARGS[1]:-docker.m.daocloud.io/library/$REPO:$TAG}
DST="$TARGET/$REPO:$TAG"

if [ -z "$TARGET" ] || [ "${ARGS[0]}" = "--help" ]; then
  cat >&2 <<EOF
用法：$0 <registry/命名空间> [来源镜像] [--from-local]

  例：$0 registry.cn-hangzhou.aliyuncs.com/your-ns
      $0 registry.cn-hangzhou.aliyuncs.com/your-ns docker.io/library/mysql:8.0
      $0 registry.cn-hangzhou.aliyuncs.com/your-ns --from-local    # 只推本机架构

推完别人这样用：
  IMAGE_MIRROR=$TARGET ./lab.sh 05
EOF
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "!! 没有 docker" >&2; exit 1; }

if [ "$FROM_LOCAL" = "1" ]; then
  # ---------- 老办法：推本机镜像（单架构）----------
  echo "==> 用本机镜像推送（单架构，仅供没有 buildx 或离线的情况）"
  docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" || {
    echo "!! 本机没有 $IMAGE，也拉不下来" >&2; exit 1; }
  SRC_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
  echo "    源镜像 ID: $SRC_ID"
  docker tag "$IMAGE" "$DST" && docker push "$DST" || {
    echo "!! 推送失败：多半是没 login，或仓库不存在/没权限" >&2; exit 1; }
  echo
  echo "    注意：这样推上去只有 $(docker info --format '{{.Architecture}}') 一个架构。"
  echo "    Apple Silicon 用户拉到会走模拟。能不这样就别这样。"
else
  # ---------- 推荐：整体复制多架构索引 ----------
  echo "==> 1. 读取来源索引：$SRC"
  SRC_DIGEST=$(docker buildx imagetools inspect "$SRC" --format '{{.Manifest.Digest}}' 2>/dev/null)
  if [ -z "$SRC_DIGEST" ]; then
    cat >&2 <<EOF
!! 读不到 $SRC 的索引。三种可能：
   - 网络到不了这个仓库（换来源：$0 $TARGET docker.io/library/$REPO:$TAG）
   - 没有 buildx（docker buildx version 看，缺就装 docker-buildx-plugin）
   - 镜像名写错了
EOF
    exit 1
  fi
  echo "    digest: $SRC_DIGEST"
  docker buildx imagetools inspect "$SRC" --format '{{range .Manifest.Manifests}}    平台 {{.Platform.OS}}/{{.Platform.Architecture}}
{{end}}' 2>/dev/null

  echo
  echo "==> 2. 整体复制到 $DST（所有架构一起，几百 MB，一两分钟）"
  docker buildx imagetools create --tag "$DST" "$SRC" || {
    cat >&2 <<EOF

!! 复制失败。常见三种：
   - unauthorized：没 login，或用的是阿里云账号密码而不是「仓库密码」
       docker login $(echo "$TARGET" | cut -d/ -f1)
   - denied：命名空间/仓库不存在，先去控制台建
   - 卡住不动：上传带宽问题，重试即可（已传的层不会重传）
EOF
    exit 1; }
fi

echo
echo "==> 3. 核对"
DST_DIGEST=$(docker buildx imagetools inspect "$DST" --format '{{.Manifest.Digest}}' 2>/dev/null)
echo "    来源 digest: ${SRC_DIGEST:-(本地推送，无索引)}"
echo "    目标 digest: ${DST_DIGEST:-（读不到，可能没权限或没 login）}"
if [ -n "${SRC_DIGEST:-}" ] && [ -n "${DST_DIGEST:-}" ]; then
  if [ "$SRC_DIGEST" = "$DST_DIGEST" ]; then
    echo "    ✓ 一致：目标仓库里就是同一个多架构索引，不是重新构建的"
  else
    echo "    ✗ 不一致：别用，检查是不是推错了 tag"
  fi
fi

echo
echo "==> 4. 仓库要设成「公开」，否则别人匿名拉会 401"
echo
echo "    别人这样用："
echo "      IMAGE_MIRROR=$TARGET ./lab.sh 05"
