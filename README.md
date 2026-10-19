# phDroid

把 [`_patchHarmony`](https://github.com/Dere3046/_patchHarmony) 的内核模块（`droid_lkm` + `droid_lkm_compat`）
封装成 **KernelSU / APatch / Magisk 通用的刷机模块**：安装时按运行内核选好构建，开机在 late_start 自动 `insmod`，
参数走配置文件，状态和日志在 WebUI 里看。

工程骨架直接沿用作者自己的 [`lkm-template`](https://github.com/Dere3046/lkm-template)，
依赖由 [`KMSDK`](https://github.com/Dere3046/KMSDK) 按名字部署，不 vendor 任何第三方源码。

## 这个模块解决什么问题

原厂 GKI `android16-6.12`（以及部分 `android15-6.6`）把 `CONFIG_SYSVIPC`、`CONFIG_POSIX_MQUEUE`、
`CONFIG_PID_NS`、`CONFIG_IPC_NS` 关掉了，Droidspaces 这类容器运行时连启动都做不到。
本模块在不重编内核、不移动任何结构体成员的前提下把这些能力补回来，预编译的 vendor 模块照常工作。

| ko | 作用 |
|---|---|
| `droid_lkm.ko` | 假 pid/ipc namespace（`unshare`/`clone`/`clone3`/`setns`）、移植的 SysV IPC（msg/sem/shm）、POSIX mqueue 与 `mqueuefs`、`/proc/<pid>/ns/{pid,ipc}`、`/proc/<pid>/status` 里的 `NSpid` 系列 |
| `droid_lkm_compat.ko` | 仅 OPPO / OnePlus / realme：vendor 模块无检查地使用 `find_task_by_vpid`、用 `p->pid` 索引数组，这里给它们一个 pid 受限的 ghost task |

## 技术栈

按上游的实现分工，各管一段：

- **KallRecon** —— 符号解析。加载时在内存里重建 kallsyms，不依赖 `kallsyms_lookup_name` 是否导出，
  也绕开 `kptr_restrict`；`droid_lkm_sym()` 全部走它。
- **HooKern** —— hook 引擎。inline hook（默认）+ kprobe，写路径默认用内核自己的
  `aarch64_insn_patch_text`，`write_path=1` 才切到模块自算的 fixmap 写路径。
- **Type_info (TI)** —— 布局发现。用运行内核的 BTF 逐个字段比对 `ipc_namespace`、`pid_namespace`、
  `nsproxy`、`task_struct`、`pid/upid` 的偏移；和编译期不一致的字段会被标记并拒绝相关特性，而不是硬写。
- **KernCall** —— 系统调用表通道，18 个 IPC 槽位（6 mqueue + 12 SysV）的 64/32 位表改写。

## 支持环境

- ARM64、GKI 内核、内核允许加载未签名模块（stock GKI 默认允许）
- 主目标 `android16-6.12`、`android15-6.6`；`android13-5.10` / `android13-5.15` / `android14-5.15` /
  `android14-6.1` 也会构建（这些内核通常已有原生 namespace，加载后基本是 no-op）
- `android12-5.10` 不在构建矩阵里；安装时按 `androidNN` + 主次版本严格匹配，没有对应构建会直接拒绝，
  不会拿 `android13-5.10` 去凑
- 需要 BTF 才能做运行期布局校正；没有 BTF 的内核会退回编译期偏移并拒绝依赖布局的特性

## 安装

1. 从 Release 下载 `phDroid-<ver>.zip`（单个整包，里面含全部 KMI 的构建）
2. 在 KernelSU / APatch / Magisk 里刷入，重启。
3. 打开模块的 WebUI（KernelSU / APatch）确认 `droid_lkm` 已加载。

`customize.sh` 用 `uname -r` 同时匹配 `androidNN` 和主次版本号，例如
`6.12.23-android16-4k-g1234567` → `android16-6.12`。安装时就把对应那份 ko 放到 `ko/`，
其余构建直接删掉；匹配不上会 `abort`，不会留一个装得上却加载不了的包。
OTA 换了 KMI 需要重装模块（或重新刷合集包）。

> 模块不挂载任何文件，因此没有 `skip_mount`，也不需要 metamodule。

## 配置

`/data/adb/modules/phdroid/config.conf`，改完重启生效。

| 键 | 默认 | 说明 |
|---|---|---|
| `verbose` | 0 | 打印每个 hook 入口，排障用 |
| `gate` | 0 | 1 = 只服务 droidspaces 进程；0 = 全进程可用 |
| `mqueue` | 1 | POSIX mqueue（mqueuefs + 6 个系统调用） |
| `nspid` / `nspid_append` | 1 / 1 | 补 `NStgid/NSpid/NSpgid/NSsid`，追加到 status 末尾 |
| `skip_sysvipc` | 0 | 不接管 18 个 IPC 系统调用槽位 |
| `no_fake_ns` | 0 | 诊断：`unshare()` 假装成功但不挂命名空间 |
| `skip_do_exit` | 0 | 诊断：不注册 `do_exit` kprobe |
| `inline_hook` | 1 | 关闭后只保留 kprobe 路径 |
| `write_path` | 0 | 0 = 内核 patch 原语；1 = 模块自己的 fixmap 写（仅复现 MTK 问题） |
| `degrade` | 0 | 1 = 关键 hook 装不上也继续加载 |
| `selinux_fix` | 0 | insmod 被 EPERM 拒绝时，用真实上下文补一条 `module_load` 规则重试（需要 magiskpolicy）；会改动运行中策略，默认关闭 |
| `compat` | auto | `auto` 按品牌决定，`on`/`off` 强制 |
| `ghost` / `ghost_match` | 1 / `oplus_` | ghost task 开关与调用方模块名前缀 |
| `pid_max_cap` | 0 | 0 = 检测到 pid 索引型 vendor 模块才封顶；-1 从不；N 封顶到 N |
| `kmi_override` | 空 | 安装期强制指定 KMI，recovery 刷机时用，改完要重装 |

### 设备识别

`service.sh` 会同时读取 `ro.product.vendor.brand`、`ro.product.brand`、厂商、机型、
`ro.build.fingerprint` 和 device 名，命中 `oppo / oneplus / realme / oplus` 才加载
`droid_lkm_compat.ko`。判定结果写进日志（`device: brand=... oplus=1`），WebUI 里也有
“一加 / OPPO：是/否”和“兼容模块”两行，不用猜。

## 状态、日志与排障

- WebUI（KernelSU / APatch）：看加载状态、生效参数、日志尾部；可以“重试加载”或“清空日志”
- 日志：`/data/adb/modules/phdroid/phdroid.log`（超过 256 KB 自动轮转一份 `.1`）
- 内核侧日志：`dmesg | grep -i droid_lkm`，每个 hook 的安装结果、布局比对结果都会打印

### 崩溃闸门

加载放在 **late_start service**，不阻塞开机。`service.sh` 在 `insmod` 前落一个
`insmod.inflight` 标记并 `sync`，`insmod` 正常返回后立刻删掉；下次开机如果标记还在，
说明上一次是死在 `insmod` 里的，本次写入 `blocked` 并跳过加载，不会拿同一份 ko 连续撞开机。

处理方式：修好（换对应 KMI / 关掉 `inline_hook` / `degrade=1`）后在 WebUI 点“重试加载”，
它会同时清 `blocked`、`insmod.crash`、残留的 `insmod.inflight` 再跑一遍 `service.sh`；
或者手动 `rm /data/adb/modules/phdroid/blocked` 再重启。

核心模块和兼容模块是两段独立流程：核心已经加载时，重试仍会补加载之前失败的 `droid_lkm_compat.ko`。
WebUI 的状态也按这个分：已加载 / 加载失败 / 已阻断 / 未加载，参数分核心与兼容两块显示。

常见失败：

| 现象 | 原因 / 处理 |
|---|---|
| `kallsyms recovery failed` | 内核裁掉了 kallsyms 关键符号，KallRecon 无法重建 |
| `Required key not available` | 内核开了 `CONFIG_MODULE_SIG_FORCE`，只能自签名或改用 KernelPatch/KPM |
| `version magic ... should be` | 刷错 KMI，换对应包 |
| `Operation not permitted` | SELinux / 内核策略拒绝 `insmod`；`selinux_fix=1` 会用真实上下文补 `module_load` 规则重试，仍失败就看 dmesg 的 avc |
| `a container critical hook did not install` | 关键 hook 装不上，模块拒绝加载；`degrade=1` 可降级但不建议 |
| WebUI 显示“已阻断” | 上次 insmod 期间内核挂了，见 `insmod.crash` 与日志；处理后点“重试加载” |
| 开机异常 | 删掉 `/data/adb/modules/phdroid` 后重启，内核侧随重启清空 |

## 自己构建

```sh
scripts/fetch-deps.sh                 # 按 .sdk-version 拉 KMSDK，部署 deps.lst
scripts/build-ddkk.sh android16-6.12  # 需要 docker，DDK 容器内编译
scripts/package-module.sh             # 把 out/<kmi>/*.ko 打成 dist/*.zip
```

多个目标：`scripts/build-ddkk.sh android15-6.6 android16-6.12`。
依赖操作走 KMSDK CLI：

```sh
.sdk/scripts/sdk ls          # 注册表
.sdk/scripts/sdk add HooKern # 按推荐 rev 加入 deps.lst
.sdk/scripts/sdk audit       # 找用了但没声明的库
```

CI（`.github/workflows/build.yml`）对 6 个 KMI 矩阵构建，`package` job 汇总产物并出 zip；
打 `v*` tag 会自动发 Release。DDK 镜像 tag 失效时改 workflow 里那一行即可。

## 目录

```
Makefile / mk/deps.mk         Kbuild 入口与 KMSDK 依赖展开
deps.lst / .sdk-version       依赖清单与 SDK 版本钉子
src/ compat/                  上游模块源码
scripts/                      fetch-deps / build-ddkk / package-module / mkzip
module/                       模块外壳（刷进 /data/adb/modules/phdroid）
  module.prop  customize.sh  config.conf  uninstall.sh
  service.sh                  唯一加载入口：崩溃标记 + insmod + 兼容模块
  webroot/index.html          KernelSU / APatch WebUI（状态/日志/重试）
  META-INF/…                  Magisk 官方 update-binary
                                安装后：ko/ 存本机那份 ko，kmi 记构建名
out/<kmi>/*.ko                编译产物（gitignore）
dist/*.zip                    刷机包（gitignore）
```

## 与上游的差异

- 只保留 `droid_lkm.ko` 与 `droid_lkm_compat.ko`；上游的 `droid_lkm_toy.ko` 是探针玩具，不随包分发，
  `src/misc`（`droid_lkm_misc.ko`）上游还没接完，同样不参与构建
- `deps.lst` 里 HooKern 从 `2c85ca2` 换成 `936b978`：前者已不在仓库历史中，两者 `hk_*` 接口一致
- `fetch-deps.sh` 改用 HTTPS，公开仓库不需要 token
- 加载从 `post-fs-data` 挪到 late_start `service.sh`：不阻塞开机；`insmod` 前后用标记文件做崩溃检测，
  检测到上次死在 insmod 里就写 `blocked` 跳过，避免连续开机崩溃
- 安装期就定死 KMI（`kernels/<kmi>` → `ko/`，其余删除），开机不再逐个探测
- 新增：`config.conf`、状态/日志/WebUI、打包与矩阵 CI

## 许可与致谢

GPL-2.0，与上游一致。内核侧代码来自
[_patchHarmony](https://github.com/Dere3046/_patchHarmony)（作者 dere3046），
依赖 [KMSDK](https://github.com/Dere3046/KMSDK)、[KallRecon](https://github.com/Dere3046/KallRecon)、
[Type_info](https://github.com/Dere3046/Type_info)、[HooKern](https://github.com/Dere3046/HooKern)、
[KernCall](https://github.com/Dere3046/KernCall)；容器运行时是
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)。
