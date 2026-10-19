#!/system/bin/sh
#
# 由 Magisk 的 module_installer.sh / KernelSU 的 ksud / APatch 在解压完成后 source
#
# 只做三件事：
#   1. 用运行内核的版本号挑出对应的 KMI 构建
#   2. 只保留这一份 ko（kernels/<kmi> -> ko/），其余删掉，开机不再做候选探测
#   3. 补可执行位
#
# 依赖 KMSDK 构建：KallRecon + Type_info + KernCall + HooKern

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
command -v abort >/dev/null 2>&1 || abort() {
	ui_print "$1"
	exit 1
}

[ -n "$MODPATH" ] || MODPATH=$(cd "$(dirname "$0")" && pwd)
[ -d "$MODPATH/kernels" ] || abort "! kernels/ missing in this zip"

# ---- 环境检查 ----------------------------------------------------------
[ "$ARCH" = "arm64" ] || [ "$(uname -m)" = "aarch64" ] || \
	abort "! arm64 device required (ARCH=${ARCH:-unknown})"

RELEASE=$(uname -r)
# 6.12.23-android16-4k-g1234 -> 6.12 / android16
MAJOR_MINOR=$(echo "$RELEASE" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
ANDROID_TAG=$(echo "$RELEASE" | sed -n 's/.*\(android[0-9][0-9]*\).*/\1/p')

# ---- 选 KMI ------------------------------------------------------------
# 打分：androidNN 命中 +4，主次版本命中 +2
BEST=
BEST_SCORE=0
TIE=

for d in "$MODPATH"/kernels/*; do
	[ -d "$d" ] || continue
	K=${d##*/}
	K_ANDROID=${K%%-*}
	K_KVER=${K#*-}
	SCORE=0
	[ -n "$MAJOR_MINOR" ] && [ "$K_KVER" = "$MAJOR_MINOR" ] && SCORE=$((SCORE + 2))
	[ -n "$ANDROID_TAG" ] && [ "$K_ANDROID" = "$ANDROID_TAG" ] && SCORE=$((SCORE + 4))
	[ "$SCORE" -eq 0 ] && continue
	if [ "$SCORE" -gt "$BEST_SCORE" ]; then
		BEST=$K
		BEST_SCORE=$SCORE
		TIE=
	elif [ "$SCORE" -eq "$BEST_SCORE" ]; then
		TIE="$TIE $K"
	fi
done

# 手动覆盖（recovery 里 uname -r 是 recovery 内核，自动识别可能不准）
OVERRIDE=$(sed -n 's/^[[:space:]]*kmi_override[[:space:]]*=[[:space:]]*//p' "$MODPATH/config.conf" 2>/dev/null \
	| tail -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//')
if [ -n "$OVERRIDE" ]; then
	[ -d "$MODPATH/kernels/$OVERRIDE" ] || abort "! kmi_override=$OVERRIDE not in this zip"
	BEST=$OVERRIDE
	BEST_SCORE=99
	TIE=
	ui_print "- override : $BEST"
fi

if [ -z "$BEST" ]; then
	abort "! no build matches kernel $RELEASE; this zip has: $(ls "$MODPATH/kernels" | tr '\n' ' ')"
fi
if [ -n "$TIE" ]; then
	# 只有内核版本里没有 androidNN 时才会同分（比如 5.10 对上 12/13 两个分支）
	ui_print "! $RELEASE matches both $BEST$TIE, using $BEST"
	ui_print "  if it fails to load, set kmi_override in config.conf and reinstall"
fi

# ---- 只留这一份 ko -----------------------------------------------------
mkdir -p "$MODPATH/ko"
cp "$MODPATH/kernels/$BEST/droid_lkm.ko" "$MODPATH/ko/" || abort "! cannot copy droid_lkm.ko"
if [ -f "$MODPATH/kernels/$BEST/droid_lkm_compat.ko" ]; then
	cp "$MODPATH/kernels/$BEST/droid_lkm_compat.ko" "$MODPATH/ko/"
fi
echo "$BEST" > "$MODPATH/kmi"
rm -rf "$MODPATH/kernels"

# 上一次加载留下的状态不要带进新版本
rm -f "$MODPATH/insmod.inflight" "$MODPATH/insmod.crash" "$MODPATH/blocked"

# ---- 权限 --------------------------------------------------------------
# 管理器解压后已经落好默认权限和 secontext（/data/adb 下是 magisk_file/ksu_file），
# 这里只补可执行位，不要用 set_perm_recursive 重设上下文，否则会被改成 system_file
chmod 0755 "$MODPATH"/*.sh "$MODPATH"/META-INF/com/google/android/update-binary 2>/dev/null
chmod 0644 "$MODPATH"/module.prop "$MODPATH"/config.conf 2>/dev/null
chmod 0755 "$MODPATH"/ko "$MODPATH"/webroot 2>/dev/null
chmod 0644 "$MODPATH"/ko/*.ko 2>/dev/null

# ---- 安装摘要 ----------------------------------------------------------
BRAND=$(getprop ro.product.vendor.brand 2>/dev/null)
[ -n "$BRAND" ] || BRAND=$(getprop ro.product.brand 2>/dev/null)
MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
[ -n "$MODEL" ] || MODEL=$(getprop ro.product.model 2>/dev/null)
ui_print "- device : ${BRAND:-?} ${MODEL:-}"
ui_print "- kernel : $RELEASE"
ui_print "- kmi    : $BEST"
ui_print "- loaded : service.sh (late_start)"
ui_print "- config : \$MODDIR/config.conf"
