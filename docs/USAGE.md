# MemBar 使用教程

从零开始：**编译 → 安装 → 看懂菜单 → 用好一键清理 → 排查问题 → 卸载**。

- [1. 环境准备](#1-环境准备)
- [2. 编译与安装](#2-编译与安装)
- [3. 菜单逐项说明](#3-菜单逐项说明)
- [4. 一键清理的原理与预期](#4-一键清理的原理与预期)
- [5. 刷新间隔 / 回收强度 / 登录项](#5-刷新间隔--回收强度--登录项)
- [6. 命令行参数](#6-命令行参数)
- [7. 故障排查](#7-故障排查)
- [8. 卸载](#8-卸载)

---

## 1. 环境准备

| 需求 | 说明 |
| --- | --- |
| 系统版本 | macOS 14 或更高 |
| 工具链 | Xcode 或 Command Line Tools（提供 `swift`、`codesign`、`strip`） |
| 依赖 | **无第三方依赖**，SwiftPM 即可完成全部构建 |
| 授权 | **不需要任何授权**：无 root、无辅助功能、无全盘访问、无网络 |

检查工具链：

```bash
swift --version
xcode-select -p          # 应输出 Xcode 或 CommandLineTools 路径
```

如果 `swift` 不存在：

```bash
xcode-select --install
```

## 2. 编译与安装

```bash
cd /path/to/MemBar

./Scripts/build-app.sh      # ① 构建
./Scripts/install.sh        # ② 安装并启动
```

`build-app.sh` 依次做这些事（全部自动）：

1. `swift build -c release --product MemBar -Xlinker -dead_strip`；
2. 组装 `build/MemBar.app`（`Contents/MacOS/MemBar` + `Info.plist` + `PkgInfo`）；
3. 首次构建时用 `Scripts/GenerateAppIcon.swift` 生成 `Resources/AppIcon.icns`（该文件不入库）；
4. `strip -x` 去掉本地符号；
5. ad-hoc 签名 `codesign --force --sign -` 并 `--verify --strict`；
6. 冒烟测试：跑一次 `--diagnostics` 打印采样，确认二进制可执行。

`install.sh` 会：退出正在运行的 MemBar → `rm -rf /Applications/MemBar.app` → 复制 → `open`。

可选环境变量：

```bash
CONFIG=debug ./Scripts/build-app.sh                     # 调试构建
SIGN_IDENTITY="MemBar Local" ./Scripts/build-app.sh     # 用固定自签身份签名
```

> **签名提示**：默认 ad-hoc 签名，每次重新构建 cdhash 都会变，macOS 会把它当成"新 App"重新登记登录项，属正常现象。
> 想避免反复登记，用同一个自签证书并传 `SIGN_IDENTITY`。

验证安装：

```bash
pgrep -x MemBar                                               # 应恰好一个 pid
/Applications/MemBar.app/Contents/MacOS/MemBar --diagnostics  # 打印一次采样后退出
```

首次启动后会发生什么：

1. 菜单栏出现内存芯片图标 + 百分比（例：`71%`）；Dock 里**没有**图标。
2. 若 App 已位于 `/Applications`，首次启动会自动注册登录项。
3. 日志写在 `~/Library/Logs/MemBar.log`，只有启动、清理、登录项变更三类记录。
4. 再次启动不会出现第二个图标（单实例保护，会激活已有实例）。

## 3. 菜单逐项说明

```
内存 71% · 已用 11.4 GB / 16 GB            ← 汇总行（不可点击）
空闲 200 MB · 缓存 3.9 GB · 压缩 4.3 GB      ← 明细（不可点击）
交换 2.8 GB / 4 GB · 🟡 偏高                ← 交换用量 + 压力估值
──────────────
⚡ 一键清理                       ⌘K
上次清理：空闲 490 MB → 440 MB，缓存 3.85 GB → 3.76 GB，
         未获得可回收缓存 · 用时 789 毫秒 · 12 秒前
高占用进程 ▸
──────────────
刷新间隔 ▸   2 秒 / 5 秒✓ / 10 秒
回收强度 ▸   64 MB✓ / 128 MB / 256 MB / 512 MB
☑ 登录时自动启动
──────────────
退出 MemBar                       ⌘Q
```

| 菜单项 | 说明 |
| --- | --- |
| 内存 x% · 已用 / 总量 | `已用 = active + wired + compressed`，百分比**向上取整**（0.1% 也不会显示 0%） |
| 空闲 / 缓存 / 压缩 | `空闲 = free + speculative`；`缓存 = inactive + speculative + purgeable`；压缩 = 压缩器占用的物理页 |
| 交换 a / b · 🟢🟡🔴 | 来自 `sysctl vm.swapusage`，与活动监视器同源；压力等级是**估算值** |
| ⚡ 一键清理 | 执行清理流水线；执行中标题变为 `正在清理…` 且禁用，结束后恢复 |
| 上次清理 | 最近一次清理（或最近一次「结束选中进程」/「登录项未生效」）的结果与相对时间 |
| 高占用进程 ▸ | **只在菜单打开时**扫描一次，列出当前用户 RSS 最大的 8 个进程 |
| 结束选中进程 (N) | 仅在勾选 ≥1 项时可用，否则禁用 |
| 刷新间隔 | 2 / 5 / 10 秒，改动立即生效并持久化 |
| 回收强度 | 内存气球大小，默认 64 MB（见第 4 节实测） |
| 登录时自动启动 | `SMAppService.mainApp`：勾选 = 注册，取消 = 注销 |
| 退出 MemBar | 结束进程（登录项状态保留） |

### 压力分级（估算）

| 等级 | 条件 | 菜单栏表现 |
| --- | --- | --- |
| 🔴 紧张 | 可回收 < 8% 物理内存 **或** swap 已用 > 4 GB | 图标换 `memorychip.fill`，百分比**红色加粗** |
| 🟡 偏高 | 可回收 < 18% **或** swap > 1 GB **或** 压缩 > 25% 物理内存 | 图标 + 百分比（默认样式） |
| 🟢 正常 | 以上都不满足 | 同上 |

> 这是 MemBar 自定的估算规则，**不等于**活动监视器的内存压力图。对照用：`memory_pressure`（内核信号）。

### 高占用进程子菜单

```
腾讯会议  398.8 MB
pi        172.0 MB
Zed        57.8 MB
──────────
结束选中进程 (0)     ← 未勾选时禁用
```

- 只列**当前用户自己的**进程；`kernel_task`、`launchd`、`WindowServer`、`Dock`、`Finder`、`SystemUIServer`、`ControlCenter`、`NotificationCenter`、`coreaudiod`、`mds*`、`cfprefsd`、`distnoted` 等系统进程以及 `pid < 100` 一律排除。
- 勾选状态每次打开菜单都会清空（避免残留误杀）。
- 结束方式：GUI App 用 `NSRunningApplication.terminate()`（有未保存文档时会弹保存框），普通进程用 `SIGTERM`；**等 3 秒仍未退出就报告「未能结束」，绝不升级 `SIGKILL`**。

## 4. 一键清理的原理与预期

三步，全部无需 root、无需密码，任一步失败只记录不中断：

1. **释放自身内存**：`malloc_zone_pressure_relief(nil, 0)`。MemBar 自身常驻约 18 MB，这一步通常是 0。
2. **内存气球**：`MemBar --balloon <MB>` 子进程 `mmap` 一块匿名内存，按 8 MB 分段 `memset` 逐页触碰（段间 `usleep 20ms` 给内核回收机会），随后 `munmap` 退出；3 秒超时会 `SIGKILL` 子进程。常驻进程 RSS 不受影响。
3. **结束勾选进程**（默认无勾选项 → 跳过）。

之后取清理后快照，生成结果行并写日志：

```
2026-11-24 14:53:01 [INFO] clean balloon=64MB ran=true
  free=452476928→436518912 cache=4367040512→4407427072 compressed=4475076608→4471685120
  stress=elevated→elevated selfRelief=0 terminated=[] stuck=[] reclaimed=no duration=0.79s
```

### 期望值（实测，别抱太高期望）

同一台 16 GB / 压缩 4.3 GB / swap 已用 2.8 GB 的机器上各跑 3 次：

| 气球 | freeΔ（MB） | compressedΔ（MB） | 耗时 |
| --- | --- | --- | --- |
| 64 MB | -0.4 / +17.9 / -0.1 | ≈ 0 | ~0.2–0.8 s |
| 128 MB | -58.6 / +24.3 / -0.6 | ≈ 0 | ~0.5 s |
| 256 MB | -0.2 / -212.5 / -8.6 | ≤ ±3 | ~0.8 s |

**结论：气球带来的净回收中位数约为 0。** 系统处于压缩/换页压力下时，腾出的页几乎立刻被重新使用。
所以默认值定为 **64 MB**；没有收益时结果行会明确写 `未获得可回收缓存`，不会虚报。

> 真正能立刻拿回内存的是第 3 步「结束高占用进程」，这是 macOS 上无 root 权限时唯一可靠的手段。
> `purge` / `sudo purge` 需要 root，本工具按产品决策**不采用**（不弹密码、不写 sudoers）。

## 5. 刷新间隔 / 回收强度 / 登录项

- **刷新间隔**：`UserDefaults` 键 `mb.refreshSeconds`（2 / 5 / 10，默认 5）。每次 tick 只做 1 次 `host_statistics64` + 2 次 `sysctlbyname`，开销在纳秒级。
- **回收强度**：键 `mb.balloonMB`（64 / 128 / 256 / 512，默认 64）。数值越大子进程瞬时占用越大，但实测收益并不随之提升。
- **登录项**：`SMAppService.mainApp`。若显示「需在系统设置允许」，去 系统设置 → 通用 → 登录项 打开；若显示「请先安装到 /Applications」，说明 App 还在 `build/` 目录（`SMAppService` 只对已安装位置生效）。

重置所有偏好：

```bash
defaults delete com.jvz.membar
```

### 性能特征（供调参参考）

| 指标 | 实测 | 说明 |
| --- | --- | --- |
| 物理 footprint | ~17.6 MB | 活动监视器「内存」列口径 |
| RSS（`ps`） | ~77 MB | 与空白 AppKit 菜单栏 App 基线持平，多为共享页 |
| 空闲 CPU（5 秒刷新） | ~0.09% | 默认档 |
| 空闲 CPU（2 秒刷新） | ~0.72% | 每次文字变化约 20 ms（WindowServer 往返） |

想进一步降 CPU：用 5 秒或 10 秒刷新档。`StatusItemController` 已做三件事——固定宽度状态栏项、仅在百分比取整值或压力等级变化时重绘、明细行只在菜单打开时重建。

## 6. 命令行参数

以下为**内部诊断参数，不作为稳定接口**：

| 参数 | 作用 |
| --- | --- |
| `--diagnostics` | 打印一次采样（自身 RSS/线程、已用/缓存/空闲/可回收/压缩/有线、交换、压力）后退出 |
| `--clean [MB]` | 用与「一键清理」完全相同的流水线跑一次（不结束进程），打印前后对比 |
| `--balloon <MB>` | 只跑内存气球子进程（清理流程会自己调用它） |
| `--selftest` | 启动 UI 并自检：菜单栏可见性与文字、菜单结构/文案/enabled 状态、压力红色渲染、刷新间隔/回收强度切换、一键清理、结束进程、登录项注册-注销往返、偏好读写；通过时输出 `自检结果: OK` 并以 0 退出 |

用法：

```bash
BIN=./build/MemBar.app/Contents/MacOS/MemBar     # 或 /Applications/MemBar.app/Contents/MacOS/MemBar

$BIN --diagnostics
$BIN --clean 128
$BIN --selftest
```

`--diagnostics` 输出示例：

```
MemBar 1.0.0 诊断
自身: pid 4821 · RSS 6.4 MB · 线程 3
物理内存: 16.0 GB · pageSize 16384
已用 11.4 GB (71%) · 缓存 3.9 GB · 空闲 200 MB
可回收 4.1 GB (26%) · 压缩 4.3 GB · 有线 3.1 GB
交换 2.8 GB / 4.0 GB (70%)
压力: 🟡 偏高 (估算)
采样时间: 2026-11-24 14:53:01
```

## 7. 故障排查

| 现象 | 处理 |
| --- | --- |
| 菜单栏没有图标 | `pgrep -x MemBar` 确认进程；若已有进程先 `osascript -e 'quit app "MemBar"'` 再启动；菜单栏项过多时系统可能隐藏 |
| 再次启动没反应 | 单实例保护：第二个实例会激活已有实例并退出（日志 `second instance detected`） |
| 百分比不动 | 检查「刷新间隔」是否设为 10 秒；系统极度紧张时定时器可能被延迟 |
| 一键清理后数字没变好 | 预期行为，见第 4 节；请改用「高占用进程」结束不用的 App |
| 「结束选中进程」灰色 | 没有勾选任何进程；勾选后标题变为 `结束选中进程 (1)` |
| 提示「未能结束」 | 该 App 拒绝退出（未保存文档 / 正在弹窗）；MemBar 不会强杀 |
| 登录项打勾但重启后没图标 | 系统设置 → 通用 → 登录项 确认 MemBar 处于允许状态；ad-hoc 重建后可能需重新勾选 |
| 图标一直是红色 | 可回收 < 8% 或 swap > 4 GB；此时结束大进程或重启更有效 |
| `swift build` 报错 | 确认 `xcode-select -p` 指向有效工具链；`swift package clean` 后重试 |
| 签名/启动被拦截 | 重建后右键 App → 打开，或 `xattr -dr com.apple.quarantine /Applications/MemBar.app` |

日志（只有生命周期与清理记录）：

```bash
tail -20 ~/Library/Logs/MemBar.log
```

## 8. 卸载

```bash
osascript -e 'quit app "MemBar"'          # 或菜单「退出 MemBar」
rm -rf /Applications/MemBar.app
rm -f ~/Library/Logs/MemBar.log ~/Library/Logs/MemBar.log.1
defaults delete com.jvz.membar
```

登录项：卸载前在菜单里取消「登录时自动启动」（或在 系统设置 → 通用 → 登录项 里移除，系统会提示残留项已失效）。

源码侧清理（`build/`、`.build/`、`Resources/AppIcon.icns` 均已在 `.gitignore`）：

```bash
swift package clean
rm -rf build .build Resources/AppIcon.icns
```
