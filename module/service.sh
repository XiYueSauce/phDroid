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

# insmod 带崩溃标记执行，参数按位置逐个传入，避免 * 被 shell 当通配符展开
guarded_insmod() {
	f=$1
	shift
	: > "$MARK" 2>/dev/null
	command -v sync >/dev/null 2>&1 && sync
	out=$(insmod_ko "$f" "$@")
	rc=$?
	rm -f "$MARK" 2>/dev/null
	command -v sync >/dev/null 2>&1 && sync
	[ -n "$out" ] && ph_log "insmod: $out"
	return $rc
}

is_oplus() {
	for p in ro.product.vendor.brand ro.product.brand ro.product.manufacturer \
		ro.product.vendor.manufacturer ro.build.product; do
		v=$(getprop "$p" 2>/dev/null | tr 'A-Z' 'a-z')
		case "$v" in
		*oppo* | *oneplus* | *realme* | *oplus*) return 0 ;;
		esac
	done
	return 1
}

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

# ---- 主模块 ------------------------------------------------------------
if loaded droid_lkm; then
	ph_log "droid_lkm already loaded"
	exit 0
fi

KMI=$(cat "$MODDIR/kmi" 2>/dev/null)
KO=$MODDIR/ko/droid_lkm.ko
if [ ! -f "$KO" ]; then
	ph_log "ko missing: $KO (reinstall the module)"
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

if [ "$rc" -ne 0 ] || ! loaded droid_lkm; then
	ph_log "droid_lkm load failed (rc=$rc)"
	dmesg 2>/dev/null | tail -n 15 >> "$LOG"
	exit 1
fi
ph_log "droid_lkm loaded"

# ---- vendor 兼容模块（仅 OPPO/OnePlus/realme） -------------------------
COMPAT=$MODDIR/ko/droid_lkm_compat.ko
want_compat=0
case "$(conf compat auto)" in
off | 0 | no | false) want_compat=0 ;;
on | 1 | yes | true) want_compat=1 ;;
*) is_oplus && want_compat=1 ;;
esac

if [ "$want_compat" = 1 ] && [ -f "$COMPAT" ] && ! loaded droid_lkm_compat; then
	ph_log "loading droid_lkm_compat.ko"
	guarded_insmod "$COMPAT" \
		"ghost=$(bool ghost 1)" \
		"ghost_match=$(conf ghost_match oplus_)" \
		"pid_max_cap=$(uint pid_max_cap 0)" \
		"inline_hook=$(bool inline_hook 1)"
	rc=$?
	if [ "$rc" -eq 0 ] && loaded droid_lkm_compat; then
		ph_log "droid_lkm_compat loaded"
	else
		ph_log "droid_lkm_compat failed (rc=$rc)"
	fi
fi

exit 0
