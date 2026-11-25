# MemBar 使用教程

从零开始：**编译 → 安装 → 看懂面板 → 用好一键清理 → 排查问题 → 卸载**。

- [1. 环境准备](#1-环境准备)
- [2. 编译与安装](#2-编译与安装)
- [3. 面板逐项说明](#3-面板逐项说明)
- [4. 一键清理的原理与预期](#4-一键清理的原理与预期)
- [5. 刷新间隔 / 登录项](#5-刷新间隔--登录项)
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

`build-app.sh` 依次做这些事（全部自动，整个脚本有 **60 秒硬超时**：任一步超时即判构建失败，
并杀掉整棵进程树，不会让终端一直挂着）：

1. `swift build -c release --product MemBar -Xlinker -dead_strip`；
2. 组装 `build/MemBar.app`（`Contents/MacOS/MemBar` + `Info.plist` + `PkgInfo`）；
3. 首次构建时用 `Scripts/GenerateAppIcon.swift` 生成 `Resources/AppIcon.icns`（青绿底 + 白色进度环 + 三根递增柱，两个生成物都不入库）；
4. `strip -x` 去掉本地符号；
5. ad-hoc 签名 `codesign --force --sign -` 并 `--verify --strict`；
6. 冒烟测试：跑一次 `--diagnostics` 打印采样，确认二进制可执行。

`install.sh` 会：退出正在运行的 MemBar → `rm -rf /Applications/MemBar.app` → 复制 → `open`。

可选环境变量：

```bash
CONFIG=debug ./Scripts/build-app.sh                     # 调试构建
SIGN_IDENTITY="MemBar Local" ./Scripts/build-app.sh     # 用固定自签身份签名
BUILD_TIMEOUT=120 ./Scripts/build-app.sh                # 放宽构建总预算（默认 60 秒，超时=失败）
```

> 超时由 `Scripts/timeout.sh` 实现（macOS 不自带 coreutils 的 `timeout`）。超时的步骤会打印
> `error: <步骤名> 超过 60s 构建预算，判定失败` 并以非零码退出。

> **签名提示**：默认 ad-hoc 签名，每次重新构建 cdhash 都会变，macOS 会把它当成"新 App"重新登记登录项，属正常现象。
> 想避免反复登记，用同一个自签证书并传 `SIGN_IDENTITY`。

验证安装：

```bash
pgrep -x MemBar                                               # 应恰好一个 pid
/Applications/MemBar.app/Contents/MacOS/MemBar --diagnostics  # 打印一次采样后退出
```

首次启动后会发生什么：

1. 菜单栏出现压力色胶囊徽章（例：`71%`）；Dock 里**没有**图标。
2. 若 App 已位于 `/Applications`，首次启动会自动注册登录项。
3. 日志写在 `~/Library/Logs/MemBar.log`，只有启动、清理、登录项变更三类记录。
4. 再次启动不会出现第二个图标（单实例保护，会激活已有实例）。

## 3. 面板逐项说明

```
 67%   已用 10.62 GB / 16 GB       ╭──────╮
 ████████████████░░░░░░░░░░        │ 偏高 │  ← 压力胶囊（与菜单栏徽章同色）
 ● 已用    ● 缓存    ● 空闲          ╰──────╯
 ──────────────────────────────────────
 缓存                              4.55 GB
 空闲                             376.7 MB
 压缩                              2.92 GB
 交换 · 已用 65.4%           1.96 GB / 3 GB
 ┌────────────────────────────────────┐
 │           ⚡ 一键清理    ⌘K         │  ← 面板里唯一的醒目实心按钮
 └────────────────────────────────────┘
 上次清理   已释放 292 MB            12 秒前
 ──────────────────────────────────────
 高占用应用                          ›
 ──────────────────────────────────────
 刷新间隔                  2 秒  5 秒✓  10 秒
 登录时自动启动 ✓
 ──────────────────────────────────────
 退出 MemBar                        ⌘Q
```

| 面板区域 | 说明 |
| --- | --- |
| `67%   已用 / 总量` | 百分比用**压力色**（绿/橙/红）大号显示；`已用 = active + wired + compressed`，**向上取整**（0.1% 也不会显示 0%） |
| 压力胶囊 | 右上角小胶囊，填充色与菜单栏徽章同色，一眼对上号 |
| 构成条 | 三段堆叠：黑=已用、蓝=缓存、青=空闲，宽度按占物理内存的比例；下方 `● 已用 ● 缓存 ● 空闲` 是配色图例 |
| 缓存 / 空闲 / 压缩 | `缓存 = inactive + speculative + purgeable`；压缩 = 压缩器占用的物理页；数值右对齐成一列 |
| 交换 · 已用 x% | 来自 `sysctl vm.swapusage`，与活动监视器同源；占用 > 80% 时数值变红 |
| ⚡ 一键清理 | 面板里唯一的实心强调色按钮：执行清理流水线；执行中标题变 `正在清理…`，**弹窗不关闭**，结果直接替换下方结果行；`⌘K` 等效 |
| 上次清理 / 已结束 | 最近一件事（清理 / 结束应用 / 登录项未生效）的一句话结果 + 相对时间，只占一行；完整 before/after 写日志 |
| 高占用应用 › | 打开弹窗、进入这一页时**各扫描一次**，按应用聚合，列出占用最大的 8 个应用 |
| 刷新间隔 | 2 / 5 / 10 秒分段按钮，改动立即生效并持久化 |
| 登录时自动启动 | `SMAppService.mainApp`：点一下切换注册状态；状态写在行尾（`✓` / 需授权 / 未安装），不用勾选框 |
| 退出 MemBar | 结束进程（登录项状态保留） |

### 为什么面板里没有灰掉的文字

早期版本把只读行做成**被禁用的菜单项**，macOS 会自动给它们套上"不可用"外观：文字变灰、整体降透明度，
于是数字、图例、结果行都发灰、发虚，很难看清。现在整个弹窗都是自绘视图，不再有这个问题。

现在顶部信息区（百分比 / 构成条 / 图例 / 数值列 / 一键清理按钮 / 结果行）是一张**自绘卡片**：颜色由代码直接
指定，`labelColor` 满对比度，层级只靠字号和字重区分，不用灰度也不用透明度。卡片里唯一的实色块就是
「⚡ 一键清理」按钮，点哪里、看哪里都没有歧义。

同理：

- 高占用应用页没有勾选提示语：没勾选时卡片到列表最后一行就结束，「结束选中应用 (N)」按钮
  随第一行勾选出现、窗口跟着长高（`NSSize` 动态变化），不存在被按钮盖住的固定区域；
- 登录项状态写在行尾（`登录时自动启动 ✓`），不用勾选框，避免多出一列勾选位把整行右移。

### 压力分级（估算）

| 等级 | 条件 | 菜单栏徽章 |
| --- | --- | --- |
| 🟢 正常 | 以上都不满足 | 绿色胶囊 |
| 🟡 偏高 | 可回收 < 18% **或** swap > 1 GB **或** 压缩 > 25% 物理内存 | 深黄胶囊 |
| 🔴 紧张 | 可回收 < 8% 物理内存 **或** swap 已用 > 4 GB | 红色胶囊 |

> 这是 MemBar 自定的估算规则，**不等于**活动监视器的内存压力图。对照用：`memory_pressure`（内核信号）。

### 高占用应用页

```
‹ 返回                          8 个应用 · 共 4.27 GB
Google Chrome        ███████░░░░░░░░   1.3 GB
WeChat               ████████░░░░░░░   1.04 GB   ← 已勾选：名字加粗 + 行底色
Qoder CN             ███░░░░░░░░░░░░   778.1 MB
node                 █░░░░░░░░░░░░░░   352 MB
──────────────────────────────────────────────
结束选中应用 (2)                    ← 勾选后才出现，窗口同时长高
```

- **一行一应用，条形表示占比**：名字在左、大小右对齐，中间一列按「占最大那一行」的比例填充。
  没有复选框，**点整行就是勾选**；勾选后该行名字加粗并铺一层浅强调色底。
- **没有提示文字**：不勾选时列表到最后一个应用就结束，底部不留空区；勾选第一个应用后按钮出现，
  弹窗高度同步变化，不会用按钮盖住列表。

- **按应用聚合**：同一个 `.app` 的所有进程（渲染器、GPU 进程、Helper）合并成一行，尺寸相加；后缀 `·N` 表示折叠了几个进程。聚合后 Chrome 的七个 helper 只占一行，不会把列表挤满。
- 名字取自 `.app` 包名，所以显示 `IntelliJ IDEA` 而不是 `idea`，显示 `Google Chrome` 而不是 `Google Chrome Helper (Renderer)`；命令行进程（`node`、`magpie-bun`）按可执行名聚合。
- 只列**当前用户自己的**进程；`kernel_task`、`launchd`、`WindowServer`、`Dock`、`Finder`、`SystemUIServer`、`ControlCenter`、`NotificationCenter`、`coreaudiod`、`mds*`、`cfprefsd`、`distnoted` 等系统进程以及 `pid < 100` 一律排除。
- 勾选状态每次打开弹窗都会清空（避免残留误杀）。
- 没勾选任何应用时**没有按钮、也没有提示语**：卡片到列表最后一行就结束。勾选后按钮出现，弹窗高度增加「间距 + 按钮高」共 42 pt，取消全部勾选后再缩回去。
- 勾选后点「结束选中应用」会**结束该应用的全部进程**：GUI App 先走 `NSRunningApplication.terminate()`（有未保存文档时会弹保存框），普通进程用 `SIGTERM`；**等 3 秒仍未退出就报告「未能结束」，绝不升级 `SIGKILL`**。

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
所以气球固定为 **64 MB** 且**不再在面板里提供调节**（原先的「回收强度」选项已移除，因为调大档位实测收益并不提升，只会让人误以为有用）。
没有收益时结果行会明确写 `未获得可回收缓存`，不会虚报。

> 真正能立刻拿回内存的是第 3 步「结束高占用进程」，这是 macOS 上无 root 权限时唯一可靠的手段。
> `purge` / `sudo purge` 需要 root，本工具按产品决策**不采用**（不弹密码、不写 sudoers）。

## 5. 刷新间隔 / 登录项

- **刷新间隔**：`UserDefaults` 键 `mb.refreshSeconds`（2 / 5 / 10，默认 5）。每次 tick 只做 1 次 `host_statistics64` + 2 次 `sysctlbyname`，开销在纳秒级。
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

想进一步降 CPU：用 5 秒或 10 秒刷新档。`StatusItemController` 已做三件事——固定宽度状态栏项、仅在百分比取整值或压力等级变化时重绘、面板卡片只在不可见时更新数据（真正绘制发生在弹出的瞬间）。

徽章（`MenuBarBadge`）也按这三条原则设计：宽度按 `100%` 定死、2× 位图绘制避免 Retina 放大发虚、图片按 `(百分比, 等级)` 缓存复用，所以稳态下每秒的开销只是一次 syscall 采样。

## 6. 命令行参数

以下为**内部诊断参数，不作为稳定接口**：

| 参数 | 作用 |
| --- | --- |
| `--diagnostics` | 打印一次采样（自身 RSS/线程、已用/缓存/空闲/可回收/压缩/有线、交换、压力）后退出 |
| `--clean [MB]` | 用与「一键清理」完全相同的流水线跑一次（不结束进程），打印前后对比 |
| `--balloon <MB>` | 只跑内存气球子进程（清理流程会自己调用它） |
| `--selftest` | 启动 UI 并自检：菜单栏徽章可见性/尺寸/缓存、弹窗结构（面板卡片高度/宽度/按钮）、面板文案、⌘K 是否真的路由到清理、压力配色切换、刷新间隔切换、一键清理、结束进程、勾选/提示行切换、登录项注册-注销往返、偏好读写；通过时输出 `自检结果: OK` 并以 0 退出。整个自检有 55 秒硬上限，超时也会以非零码退出（不会挂死） |
| `--preview <dir>` | 把三张卡片离屏渲染成 PNG（`sheet-main` / `sheet-processes` / `panel` / `actions` / `processes`），用于比对 UI 而不必真的点开弹窗 |

用法：

```bash
BIN=./build/MemBar.app/Contents/MacOS/MemBar     # 或 /Applications/MemBar.app/Contents/MacOS/MemBar

$BIN --diagnostics
$BIN --clean 128
$BIN --selftest
$BIN --preview /tmp/membar-preview
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
| 菜单栏没有徽章 | `pgrep -x MemBar` 确认进程；若已有进程先 `osascript -e 'quit app "MemBar"'` 再启动；**菜单栏项太多时 macOS 会把徽章折叠进 `«` 溢出区**，可用 ⌘ 拖出或减少菜单栏项 |
| 再次启动没反应 | 单实例保护：第二个实例会激活已有实例并退出（日志 `second instance detected`） |
| 百分比不动 | 检查「刷新间隔」是否设为 10 秒；系统极度紧张时定时器可能被延迟 |
| 一键清理后数字没变好 | 预期行为，见第 4 节；请改用「高占用进程」结束不用的 App |
| 「结束选中进程」灰色 | 没有勾选任何进程；勾选后标题变为 `结束选中进程 (1)` |
| 提示「未能结束」 | 该 App 拒绝退出（未保存文档 / 正在弹窗）；MemBar 不会强杀 |
| 登录项打勾但重启后没图标 | 系统设置 → 通用 → 登录项 确认 MemBar 处于允许状态；ad-hoc 重建后可能需重新勾选 |
| 徽章一直是红色 | 可回收 < 8% 或 swap > 4 GB；此时结束大进程或重启更有效 |
| `swift build` 报错 | 确认 `xcode-select -p` 指向有效工具链；`swift package clean` 后重试 |
| 签名/启动被拦截 | 重建后右键 App → 打开，或 `xattr -dr com.apple.quarantine /Applications/MemBar.app` |

日志（只有生命周期与清理记录）：

```bash
tail -20 ~/Library/Logs/MemBar.log
```

## 8. 卸载

```bash
osascript -e 'quit app "MemBar"'          # 或面板底部「退出 MemBar」
rm -rf /Applications/MemBar.app
rm -f ~/Library/Logs/MemBar.log ~/Library/Logs/MemBar.log.1
defaults delete com.jvz.membar
```

登录项：卸载前在面板里取消「登录时自动启动」（或在 系统设置 → 通用 → 登录项 里移除，系统会提示残留项已失效）。

源码侧清理（`build/`、`.build/`、`Resources/AppIcon.icns` 均已在 `.gitignore`）：

```bash
swift package clean
rm -rf build .build Resources
```
