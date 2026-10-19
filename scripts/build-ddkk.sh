#!/bin/sh
# 本地 DDK 构建
# 用法: build-ddkk.sh [target ...]
# 默认只构建 android16-6.12，传多个目标会依次构建
# 产物落在 out/<target>/{droid_lkm,droid_lkm_compat}.ko
set -e

SRCDIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${DDK_IMAGE:-docker.cnb.cool/ylarod/ddk/ddk-min}
TARGETS=${*:-android16-6.12}

command -v docker >/dev/null 2>&1 || {
	echo "docker not found: DDK builds run in the ddk-min container" >&2
	exit 1
}

for TARGET in $TARGETS; do
	echo "==> $TARGET"
	docker run --rm \
		-e KDIR=/opt/ddk/kdir/${TARGET} \
		-v "$SRCDIR":/src \
		-w /src \
		"$IMAGE:$TARGET" \
		sh -c 'make VER="$1" clean >/dev/null 2>&1 || true; make VER="$1"' sh "$TARGET"

	echo "-> $SRCDIR/out/$TARGET"
	find "$SRCDIR/out/$TARGET" -name "*.ko" -print
done
