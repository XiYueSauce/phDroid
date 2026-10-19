#!/system/bin/sh
#
# 在 late_start service 阶段加载 ko
#
# 为什么不用 post-fs-data：
#   post-fs-data 是阻塞的、跑在 Zygote 之前，insmod 期间一旦内核出错会直接把开机卡死；
#   late_start 是非阻塞的，模块出问题也不会挡住系统起来。
#
# 崩溃检测：
#   insmod 前落一个标记文件（并 sync 到磁盘），insmod 正常返回后立刻删掉。
#   下次开机如果标记还在，说明上一次是死在 insmod 里的，本次直接跳过并写 blocked，
#   不再拿同一份 ko 去撞第二次开机。

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=$(pwd)

LOG=$MODDIR/phdroid.log
MARK=$MODDIR/insmod.inflight
BLOCK=$MODDIR/blocked
CONF=$MODDIR/config.conf
LOG_MAX=262144

ph_log() {
	if [ -f "$LOG" ]; then
		sz=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
		[ -n "$sz" ] && [ "$sz" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
	fi
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
	# 没权限的设备上 /dev/kmsg 会失败，先探测再写
	if [ -w /dev/kmsg ]; then
		echo "<6>phDroid: $*" > /dev/kmsg 2>/dev/null
	fi
	command -v log >/dev/null 2>&1 && log -t phDroid "$*" 2>/dev/null
	return 0
}

conf() {
	v=
	if [ -f "$CONF" ]; then
		v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
			| tail -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//')
	fi
	[ -n "$v" ] && echo "$v" || echo "$2"
}

bool() {
	case "$(conf "$1" "$2")" in
	1 | true | on | yes) echo 1 ;;
	0 | false | off | no) echo 0 ;;
	*) echo "$2" ;;
	esac
}

uint() {
	v=$(conf "$1" "$2")
	case "$v" in
	'' | *[!0-9]*) echo "$2" ;;
	*) echo "$v" ;;
	esac
}

# 允许负数：pid_max_cap 的 -1 表示“从不封顶”，不能用 uint
sint() {
	v=$(conf "$1" "$2")
	case "$v" in
	'') echo "$2" ;;
	-*)
		rest=${v#-}
		case "$rest" in
		'' | *[!0-9]*) echo "$2" ;;
		*) echo "$v" ;;
		esac
		;;
	*[!0-9]*) echo "$2" ;;
	*) echo "$v" ;;
	esac
}

loaded() {
	[ -r /proc/modules ] && grep -q "^$1 " /proc/modules
}

insmod_ko() {
	f=$1
	shift
	if command -v insmod >/dev/null 2>&1; then
		insmod "$f" "$@" 2>&1
		return $?
	fi
	for bb in "${MAGISKTMP:-/nonexistent}/busybox" \
		/data/adb/ksu/bin/busybox \
		/data/adb/ap/bin/busybox \
		/data/adb/magisk/busybox; do
		[ -x "$bb" ] || continue
		"$bb" insmod "$f" "$@" 2>&1
		return $?
	done
	echo "insmod not found"
	return 127
}

# 一次 insmod：落标记 -> 执行 -> 立刻删标记，结果留在 INS_RC / INS_OUT
try_insmod() {
	f=$1
	shift
	: > "$MARK" 2>/dev/null
	command -v sync >/dev/null 2>&1 && sync
	INS_OUT=$(insmod_ko "$f" "$@")
	INS_RC=$?
	rm -f "$MARK" 2>/dev/null
	command -v sync >/dev/null 2>&1 && sync
	return $INS_RC
}

# 只在确认是 SELinux 拒绝（EPERM）时才补一条最小规则：
# 用调用者真实域 + ko 真实上下文拼，作用域只到这个文件。
# Magisk 的 magisk 域本身是 permissive，正常不会走到这里
selinux_allow() {
	ko=$1
	mp=
	for c in magiskpolicy "${MAGISKTMP:-/nonexistent}/magiskpolicy" \
		/data/adb/magisk/magiskpolicy; do
		if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
			mp=$c
			break
		fi
	done
	[ -n "$mp" ] || return 1

	sctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
	sdom=${sctx#u:r:}
	sdom=${sdom%%:*}
	tctx=$(ls -Z "$ko" 2>/dev/null | awk '{print $1}')
	ttype=${tctx#u:object_r:}
	ttype=${ttype%%:*}
	case "$sdom" in '' | *[!a-zA-Z0-9_]*) return 1 ;; esac
	case "$ttype" in '' | *[!a-zA-Z0-9_]*) return 1 ;; esac

	"$mp" --live "allow $sdom $ttype:system module_load" >/dev/null 2>&1 || return 1
	ph_log "selinux: allow $sdom $ttype:system module_load"
	return 0
}

# 带崩溃标记执行；selinux_fix=1 且遇到 EPERM 时补规则后重试一次
guarded_insmod() {
	try_insmod "$@"
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$SX_DONE" != 1 ] && [ "$(bool selinux_fix 0)" = 1 ]; then
		case "$INS_OUT" in
		*"not permitted"* | *"Permission denied"* | *EPERM*)
			if selinux_allow "$1"; then
				SX_DONE=1
				try_insmod "$@"
				rc=$?
			fi
			;;
		esac
	fi
	[ -n "$INS_OUT" ] && ph_log "insmod: $INS_OUT"
	return $rc
}

# 设备指纹：品牌 / 厂商 / 机型 / fingerprint / device 名一起看。
# 一加、OPPO、realme 的 vendor 模块共用 oplus 前缀，fingerprint 兜底最稳
device_info() {
	d_brand=$(getprop ro.product.vendor.brand 2>/dev/null)
	[ -n "$d_brand" ] || d_brand=$(getprop ro.product.brand 2>/dev/null)
	d_model=$(getprop ro.product.vendor.model 2>/dev/null)
	[ -n "$d_model" ] || d_model=$(getprop ro.product.model 2>/dev/null)
	d_manuf=$(getprop ro.product.vendor.manufacturer 2>/dev/null)
	[ -n "$d_manuf" ] || d_manuf=$(getprop ro.product.manufacturer 2>/dev/null)
	d_fp=$(getprop ro.build.fingerprint 2>/dev/null)
	[ -n "$d_fp" ] || d_fp=$(getprop ro.vendor.build.fingerprint 2>/dev/null)
	d_dev=$(getprop ro.product.vendor.device 2>/dev/null)
	[ -n "$d_dev" ] || d_dev=$(getprop ro.product.device 2>/dev/null)
	return 0
}

is_oplus() {
	device_info
	blob=$(printf '%s %s %s %s %s' "$d_brand" "$d_manuf" "$d_model" "$d_fp" "$d_dev" | tr 'A-Z' 'a-z')
	case "$blob" in
	*oppo* | *oneplus* | *realme* | *oplus*) return 0 ;;
	esac
	return 1
}

runtime() {
	if [ -d /data/adb/ksu ]; then
		echo KernelSU
	elif [ -d /data/adb/ap ]; then
		echo APatch
	elif [ -d /data/adb/magisk ]; then
		echo Magisk
	else
		echo unknown
	fi
}

# ---- status 模式：WebUI 调用，只读不加载 ------------------------------
if [ "$1" = "status" ]; then
	device_info
	if is_oplus; then oplus=1; else oplus=0; fi
	echo "version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "manager=$(runtime)"
	echo "kernel=$(uname -r)"
	echo "kmi=$(cat "$MODDIR/kmi" 2>/dev/null)"
	if loaded droid_lkm; then echo "loaded=1"; else echo "loaded=0"; fi
	if loaded droid_lkm_compat; then echo "compat=1"; else echo "compat=0"; fi
	if [ -f "$BLOCK" ]; then echo "blocked=1"; else echo "blocked=0"; fi
	if [ -f "$MODDIR/insmod.crash" ]; then echo "crash=1"; else echo "crash=0"; fi
	echo "last=$(cat "$MODDIR/last_result" 2>/dev/null)"
	echo "oplus=$oplus"
	echo "brand=${d_brand:-?}"
	echo "model=${d_model:-?}"
	echo "fingerprint=${d_fp:-?}"
	for p in /sys/module/droid_lkm/parameters/*; do
		[ -f "$p" ] || continue
		echo "param.${p##*/}=$(cat "$p" 2>/dev/null)"
	done
	for p in /sys/module/droid_lkm_compat/parameters/*; do
		[ -f "$p" ] || continue
		echo "cparam.${p##*/}=$(cat "$p" 2>/dev/null)"
	done
	echo "---log---"
	tail -n 25 "$LOG" 2>/dev/null
	exit 0
fi

# ---- 崩溃闸门 ----------------------------------------------------------
if [ -f "$MARK" ]; then
	mv -f "$MARK" "$MODDIR/insmod.crash" 2>/dev/null
	: > "$BLOCK" 2>/dev/null
	ph_log "previous insmod never returned, kernel died inside it; blocked (remove $BLOCK or use the WebUI retry)"
	exit 0
fi
if [ -f "$BLOCK" ]; then
	ph_log "blocked by $BLOCK, skip loading"
	exit 0
fi

# ---- 核心模块 ----------------------------------------------------------
KMI=$(cat "$MODDIR/kmi" 2>/dev/null)
if is_oplus; then oplus=1; else oplus=0; fi
ph_log "device: brand=${d_brand:-?} model=${d_model:-?} oplus=$oplus"

core_ok=0
if loaded droid_lkm; then
	ph_log "droid_lkm already loaded, skip core insmod"
	core_ok=1
else
	KO=$MODDIR/ko/droid_lkm.ko
	if [ ! -f "$KO" ]; then
		ph_log "ko missing: $KO (reinstall the module)"
		echo "fail: core ko missing" > "$MODDIR/last_result"
		exit 1
	fi

	ph_log "loading droid_lkm.ko (kmi=${KMI:-unknown}), kernel=$(uname -r)"
	guarded_insmod "$KO" \
		"verbose=$(bool verbose 0)" \
		"gate=$(bool gate 0)" \
		"mqueue=$(bool mqueue 1)" \
		"nspid=$(bool nspid 1)" \
		"nspid_append=$(bool nspid_append 1)" \
		"skip_sysvipc=$(bool skip_sysvipc 0)" \
		"no_fake_ns=$(bool no_fake_ns 0)" \
		"skip_do_exit=$(bool skip_do_exit 0)" \
		"inline_hook=$(bool inline_hook 1)" \
		"write_path=$(bool write_path 0)" \
		"degrade=$(bool degrade 0)"
	rc=$?

	if [ "$rc" -eq 0 ] && loaded droid_lkm; then
		core_ok=1
		ph_log "droid_lkm loaded"
		echo "ok: core" > "$MODDIR/last_result"
	else
		ph_log "droid_lkm load failed (rc=$rc)"
		echo "fail: core rc=$rc" > "$MODDIR/last_result"
		dmesg 2>/dev/null | tail -n 15 >> "$LOG"
	fi
fi

# 核心没起来，兼容模块没有意义
[ "$core_ok" = 1 ] || exit 1

# ---- vendor 兼容模块（独立阶段：核心已加载也会补加载） -----------------
# 只有 OPPO / OnePlus / realme 的 vendor 模块会无检查地用 find_task_by_vpid
COMPAT=$MODDIR/ko/droid_lkm_compat.ko
want_compat=0
case "$(conf compat auto)" in
off | 0 | no | false) want_compat=0 ;;
on | 1 | yes | true) want_compat=1 ;;
*) [ "$oplus" = 1 ] && want_compat=1 ;;
esac

if [ "$want_compat" != 1 ]; then
	ph_log "compat: not needed (oplus=$oplus, compat=$(conf compat auto))"
elif [ ! -f "$COMPAT" ]; then
	ph_log "compat: no build in this package"
elif loaded droid_lkm_compat; then
	ph_log "droid_lkm_compat already loaded"
else
	ph_log "loading droid_lkm_compat.ko"
	guarded_insmod "$COMPAT" \
		"ghost=$(bool ghost 1)" \
		"ghost_match=$(conf ghost_match oplus_)" \
		"pid_max_cap=$(sint pid_max_cap 0)" \
		"inline_hook=$(bool inline_hook 1)"
	rc=$?
	if [ "$rc" -eq 0 ] && loaded droid_lkm_compat; then
		ph_log "droid_lkm_compat loaded"
		echo "ok: core+compat" > "$MODDIR/last_result"
	else
		ph_log "droid_lkm_compat failed (rc=$rc)"
		echo "fail: compat rc=$rc" > "$MODDIR/last_result"
	fi
fi

exit 0
