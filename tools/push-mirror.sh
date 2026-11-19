#!/usr/bin/env bash
# 把 lab 用的镜像推到你自己的国内仓库（阿里云 ACR / 公司 harbor），让别人拉得快。
#
#   ./tools/push-mirror.sh registry.cn-hangzhou.aliyuncs.com/your-ns
#
# 推完以后，别人这样用（不用改任何文件）：
#   IMAGE_MIRROR=registry.cn-hangzhou.aliyuncs.com/your-ns ./lab.sh 05
#
# 阿里云 ACR 个人版注意三点：
#   1) 先建命名空间和仓库，仓库要设成「公开」，否则别人拉会 401
#   2) 登录用的是「仓库密码」（固定密码），不是阿里云账号密码：
#        docker login registry.cn-hangzhou.aliyuncs.com
#   3) 个人版有存储和流量额度，别把它当成唯一来源 —— lab.sh 里它只是「排最前面试」，
#      拉不动会自动回退官方源和公共加速站
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TARGET=${1:-}
IMAGE=${MYSQL_IMAGE:-mysql:8.0}
REPO=${IMAGE%%:*}
TAG=${IMAGE##*:}

if [ -z "$TARGET" ]; then
  cat >&2 <<EOF
用法：$0 <registry/命名空间>

  例：$0 registry.cn-hangzhou.aliyuncs.com/your-ns
      $0 harbor.internal.example.com/dba

推完别人这样用：
  IMAGE_MIRROR=$TARGET ./lab.sh 05
EOF
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "!! 没有 docker" >&2; exit 1; }

echo "==> 1. 确认本地有 $IMAGE"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "    本地没有，先拉一把"
  docker pull "$IMAGE" || { echo "!! 拉取失败，先解决网络" >&2; exit 1; }
fi
SRC_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE")
echo "    源镜像 ID: $SRC_ID"

echo
echo "==> 2. 打标签并推送"
docker tag "$IMAGE" "$TARGET/$REPO:$TAG" || exit 1
docker push "$TARGET/$REPO:$TAG" || {
  cat >&2 <<EOF

!! 推送失败。常见三种：
   - unauthorized：没登录，或用的是阿里云账号密码而不是「仓库密码」
       docker login $TARGET
   - denied: requested access to the resource is denied：命名空间/仓库不存在，先去控制台建
   - 卡在 Pushing：上传带宽问题，重试即可（已传的层不会重传）
EOF
  exit 1
}

echo
echo "==> 3. 核对：目标仓库里的镜像和源镜像是同一个"
echo "    在另一台机器（或换掉本地标签后）跑："
cat <<EOF
      docker pull $TARGET/$REPO:$TAG
      docker image inspect -f '{{.Id}}' $TARGET/$REPO:$TAG
EOF
echo "    这个 ID 应该等于 $SRC_ID"
echo "    （别用 digest 比：push 上去的是单架构 manifest，digest 和官方多架构索引天然不同）"

echo
echo "==> 4. 别忘了把仓库设成「公开」，否则别人匿名拉会 401"
echo
echo "    然后别人可以："
echo "      IMAGE_MIRROR=$TARGET ./lab.sh 05"
