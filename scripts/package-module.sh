#!/bin/sh
# 把 out/<kmi>/*.ko 打成可直接刷入的 Magisk / KernelSU / APatch 模块 zip
#
# 用法:
#   scripts/package-module.sh                       # 自动发现 out/ 下已构建的 KMI
#   scripts/package-module.sh android16-6.12        # 只打指定 KMI
#   scripts/package-module.sh --version v1.0.1 --code 2
#
# 产物:
#   dist/phDroid-<ver>-<kmi>.zip    单 KMI，体积最小
#   dist/phDroid-<ver>-all.zip      全 KMI 合集，装机时按运行内核挑
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTDIR=$ROOT/dist
# 暂存目录放在工程内，Windows 上 mktemp 给出的是 C:\... 形式，
# 清理时会被 safe-delete 当成相对路径处理而失败
STAGE=$ROOT/build/stage
VERSION=
CODE=
KMIS=

usage() {
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case $1 in
	--version) VERSION=$2; shift 2 ;;
	--version=*) VERSION=${1#*=}; shift ;;
	--code) CODE=$2; shift 2 ;;
	--code=*) CODE=${1#*=}; shift ;;
	--out) OUTDIR=$2; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	-*) echo "unknown option: $1" >&2; exit 1 ;;
	*) KMIS="$KMIS $1"; shift ;;
	esac
done

# 版本号、versionCode 默认取 module.prop
prop_get() {
	awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$ROOT/module/module.prop"
}
[ -n "$VERSION" ] || VERSION=$(prop_get version)
[ -n "$CODE" ] || CODE=$(prop_get versionCode)
[ -n "$VERSION" ] || { echo "no version" >&2; exit 1; }
[ -n "$CODE" ] || CODE=1

prop_set() {
	awk -F= -v k="$2" -v v="$3" '
		BEGIN { done = 0 }
		$1 == k { print k "=" v; done = 1; next }
		{ print }
		END { if (!done) print k "=" v }
	' "$1" > "$1.tmp"
	mv "$1.tmp" "$1"
}

# 没指定就用 out/ 里真正产出了 droid_lkm.ko 的目录
if [ -z "${KMIS# }" ]; then
	for d in "$ROOT"/out/*/; do
		[ -f "$d/droid_lkm.ko" ] || continue
		KMIS="$KMIS $(basename "$d")"
	done
fi
KMIS=$(echo $KMIS | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')
[ -n "$KMIS" ] || {
	echo "no built module found under $ROOT/out" >&2
	exit 1
}

# 清空暂存目录：用 find -delete 而不是 rm -rf，
# 后者在部分环境（Windows 回收站守卫）会直接失败
clean_dir() {
	[ -d "$1" ] || return 0
	find "$1" -mindepth 1 -delete 2>/dev/null || rm -rf "$1"
}

stage() { # <kmi>...
	clean_dir "$STAGE"
	mkdir -p "$STAGE"
	cp -a "$ROOT/module/." "$STAGE/"
	mkdir -p "$STAGE/kernels"

	for k in "$@"; do
		[ -f "$ROOT/out/$k/droid_lkm.ko" ] || {
			echo "missing $ROOT/out/$k/droid_lkm.ko" >&2
			exit 1
		}
		mkdir -p "$STAGE/kernels/$k"
		cp "$ROOT/out/$k/droid_lkm.ko" "$STAGE/kernels/$k/"
		# compat 只有部分 KMI 会构建出来（取决于目标内核有没有 nop_mnt_idmap）
		if [ -f "$ROOT/out/$k/droid_lkm_compat.ko" ]; then
			cp "$ROOT/out/$k/droid_lkm_compat.ko" "$STAGE/kernels/$k/"
		fi
	done

	prop_set "$STAGE/module.prop" version "$VERSION"
	prop_set "$STAGE/module.prop" versionCode "$CODE"

	# 安装脚本必须可执行，解压后管理器多半按 0644 落盘，这里先定好
	chmod 0755 "$STAGE"/*.sh "$STAGE"/META-INF/com/google/android/update-binary
}

make_zip() { # <zip path>
	mkdir -p "$(dirname "$1")"
	# 不先 rm：部分环境的删除守卫会把“删除不存在的文件”当失败处理；
	# zip 用 -FS 同步，python 写入本身就是截断
	if command -v zip >/dev/null 2>&1; then
		(cd "$STAGE" && zip -qr9 -FS "$1" .)
	else
		# Windows 上的 python 不认 /c/... 形式的路径，先转成 C:\...
		winpath() {
			if command -v cygpath >/dev/null 2>&1; then
				cygpath -w "$1"
			else
				echo "$1"
			fi
		}
		for py in python3 python py; do
			command -v "$py" >/dev/null 2>&1 || continue
			"$py" "$(winpath "$ROOT/scripts/mkzip.py")" \
				"$(winpath "$STAGE")" "$(winpath "$1")"
			break
		done
	fi
	[ -f "$1" ] || { echo "failed to create $1" >&2; exit 1; }
}

echo "version: $VERSION ($CODE)"
echo "kmis   : $KMIS"

for k in $KMIS; do
	stage "$k"
	prop_set "$STAGE/module.prop" version "$VERSION ($k)"
	z="$OUTDIR/phDroid-$VERSION-$k.zip"
	make_zip "$z"
	echo "  $z"
done

set -- $KMIS
if [ $# -gt 1 ]; then
	stage "$@"
	z="$OUTDIR/phDroid-$VERSION-all.zip"
	make_zip "$z"
	echo "  $z"
fi

clean_dir "$STAGE"
rmdir "$STAGE" 2>/dev/null || true
rmdir "$ROOT/build" 2>/dev/null || true
echo "done, see $OUTDIR"
