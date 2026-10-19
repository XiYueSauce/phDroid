#!/bin/sh
# 通过 KMSDK 部署 deps.lst 声明的依赖
# .sdk-version 钉住 SDK 的 commit，SDK 自身克隆到 .sdk/（已 gitignore）
# 依赖库由 SDK 按 libs.lst 里的 URL 拉取，本仓库不 vendor 任何第三方源码
set -e

cd "$(dirname "$0")/.."

# 默认走 HTTPS，公开仓库不需要 token；
# 私有镜像或内网可以覆盖 KMSDK_URL
SDK_URL=${KMSDK_URL:-https://github.com/Dere3046/KMSDK.git}
SDKREV=$(cat .sdk-version)

if [ ! -d .sdk/.git ]; then
	rm -rf .sdk
	git clone "$SDK_URL" .sdk
fi

case $SDKREV in
[0-9a-f]*)
	git -C .sdk fetch origin 2>/dev/null || true
	git -C .sdk checkout -q "$SDKREV"
	;;
*)
	# 不是 commit id 就跟随默认分支
	git -C .sdk fetch origin
	git -C .sdk checkout -q FETCH_HEAD
	;;
esac

echo "KMSDK @ $SDKREV"
exec .sdk/scripts/sdk install
