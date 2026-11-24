# MemBar — macOS 内存监控 + 一键清理（菜单栏原生 App）

> 本文件是已批准的实施方案，实现与验收以此为准。

## 摘要

在 `/Users/jvz/code/MemBar/` 新建一个 Swift + SwiftPM（无第三方依赖、纯 AppKit、无 SwiftUI/xib）的菜单栏常驻小工具：

- 菜单栏图标右侧实时显示内存占用百分比（默认 5 秒刷新）。
- 点击图标弹出菜单：内存详情（已用/空闲/缓存/压缩/交换）、压力状态、**一键清理**、上次清理结果、高占用进程子菜单（可勾选后结束）、刷新间隔、开机自启、退出。
- 一键清理 = ① 释放本应用内存 ② 子进程「内存气球」回收可丢弃缓存 ③ 结束用户勾选的高占用进程（默认不勾选，永不杀系统/他人进程）。
- 全程零密码、零 root、零辅助功能授权、零额外系统配置。
- 内存预算目标：常驻 RSS ≤ 30 MB，空闲 CPU ≤ 0.2%。

## 决策（已由用户确认）

| 决策点 | 结论 |
| --- | --- |
| 形态 | 原生菜单栏 App（SwiftPM + `build-app.sh` + ad-hoc 签名，沿用 NanoClip 工程约定） |
| 清理层级 | 非特权回收 + 可勾选结束高占用进程（不含 `purge` / 不提权） |
| 安装 | `install.sh` 复制到 `/Applications`，登录项用 `SMAppService.mainApp`（macOS 13+），首次启动默认注册、菜单可关 |
| 权限 | 全程不要密码；不写 sudoers、不弹管理员框 |

## 假设与默认值

- 工程名/目录 `MemBar`，bundle id `com.jvz.membar`，显示名 `MemBar`，标识符图标 `memorychip`，UI/文档用中文。
- `platforms: [.macOS(.v14)]`，`LSUIElement = true`（无 Dock 图标，同 NanoClip）。
- 默认刷新间隔 5 秒（菜单内可选 2/5/10），气球上限 256 MB（菜单内可选 64/128/256/512）。
- 压力等级为**估算值**（基于 vm 统计 + swap 用量），与活动监视器内存压力表不完全一致。
- 不存历史曲线、不做偏好设置窗口、不联网、不落盘任何统计数据。

## 行为与接口设计

### 1. 内存读取（`MemBarCore/MemoryStats.swift`）

- 总量：`sysctl hw.memsize`（进程内缓存一次）。
- 页统计：`host_statistics64(mach_host_self(), HOST_VM_INFO64)` → `vm_statistics64`，`pageSize` 由 `host_page_size` 取得。
- 交换：`sysctl vm.swapusage`（`xsw_usage`）。
- 派生值（与活动监视器口径对齐）：
  - `used = (active + wired + compressed) * pageSize`
  - `cache = (inactive + speculative + purgeable) * pageSize`
  - `free = (free + speculative) * pageSize`
  - `swapTotal/swapUsed` 来自 `xsw_usage`
  - `percent = used / total`（0–100，向上取整显示）
- 单个快照结构 `MemorySnapshot`（纯值类型，便于测试）；每次 tick 只做一次 syscall 组，不分配大对象。

### 2. 压力分级（`MemBarCore/MemoryPressure.swift`）

`normal / elevated / critical`，规则：

- `freeRatio = free / total`；`swapRatio = swapUsed / swapTotal`（swapTotal 为 0 时按 0 处理）。
- `critical`：`freeRatio < 0.08` 或 `swapUsed > 4 GB`
- `elevated`：`freeRatio < 0.18` 或 `swapUsed > 1 GB` 或 `compressed > total * 0.25`
- 其余 `normal`
- 显示：🟢 正常 / 🟡 偏高 / 🔴 紧张；`critical` 时菜单栏用 `memorychip.fill` + 红色加粗百分比文本，其余用 `memorychip` + 常规文本。

### 3. 进程扫描（`MemBarCore/ProcessScanner.swift`）

- `proc_listallpids` + `proc_pidinfo(PROC_PIDTASKINFO)` 取 `pbi_resident_size` / uid / ppid；只在**菜单打开时**调用，不进入 5 秒 tick。
- 过滤：只保留 `uid == geteuid()`；排除自身 pid、`kernel_task`、`launchd`(1)、`WindowServer`、`loginwindow`、`Dock`、`Finder`、`SystemUIServer`、`ControlCenter`、`NotificationCenter`、`coreaudiod`、`mds*`、`cfprefsd`、`distnoted`、以及任何 `pid < 100` 的进程。
- 显示名：优先 `NSRunningApplication(processIdentifier:)?.localizedName`，否则 `proc_name`；按 RSS 降序取前 8 条。

### 4. 一键清理（`MemBarCore/Reclaimer.swift` + `MemBarCore/Balloon.swift`）

按顺序执行并计时，任一步失败只记录不中断（除气球子进程失败，此时跳过该步）：

1. **自身释放**：清空临时缓存对象 → `malloc_zone_pressure_relief(nil, 0)`（作用于本进程所有 zone）。
2. **内存气球**：`posix_spawn` 同二进制 `--balloon <MB>`（默认 256）→ 子进程 `mmap(MAP_ANON|MAP_PRIVATE)` 分配后 `memset` 逐页触达（分 8 MB 段推进，尾部 `usleep(20000)` 让内核有机会回收），最后 `munmap` 并退出。好处：常驻主进程 RSS 不膨胀，峰值只存在于瞬时子进程。子进程 3 秒超时后 `SIGKILL`。
3. **结束勾选进程**：对每个勾选项，若是 `NSRunningApplication` 用 `.terminate()`，否则 `/bin/kill -TERM`；轮询最多 3 秒确认退出；仍存活的只报告"未能结束"，绝不升级为 `SIGKILL`。
4. **结果**：清理前后各取一次 `MemorySnapshot`，菜单显示 `上次清理：空闲 2.1 GB → 2.6 GB（+480 MB），缓存 4.9 GB → 4.4 GB · 12 秒前`；同时 `Log.info` 记录完整前后对比。若空闲增量 < 0，文案改为"未获得可回收缓存"（不谎报效果）。

`--balloon <MB>` 与 `--diagnostics` 是同一可执行文件的内部参数，不出现在菜单里（诊断用）。

### 5. 菜单与刷新循环（`MemBar/`）

- `main.swift` → `NSApplication` + `AppDelegate`（`LSUIElement` 下 `NSApp.setActivationPolicy(.accessory)`）；`SingleInstance.exitIfAlreadyRunning()` 复用 NanoClip 写法。
- `Sampler`：`DispatchSourceTimer`（主队列，`leeway = 1s`）+ `Prefs.refreshInterval`；每次 tick 取快照、更新菜单栏标题；`critical` 时用 `formattedAttributedString` 变红。菜单打开期间不做额外定时器。
- `StatusItemController`（`NSMenuDelegate.menuWillOpen` 时重建动态项）菜单结构：

```
内存 63% · 已用 10.2 GB / 16 GB      [disabled]
空闲 3.1 GB · 缓存 4.2 GB · 压缩 1.1 GB   [disabled]
交换 1.2 GB / 4.0 GB · 🟢 正常        [disabled]
────────────────────────
⚡ 一键清理                     (⌘K)
上次清理：…（或「尚未清理」）          [disabled]
高占用进程 ▸                    (子菜单，勾选项 + 「结束选中进程 (0)」)
────────────────────────
刷新间隔 ▸  2 秒 / 5 秒✓ / 10 秒
☑ 登录时自动启动
────────────────────────
退出 MemBar                    (⌘Q)
```

- 勾选态每次 `menuWillOpen` 重置为空；「结束选中进程」仅在 ≥1 项勾选时 enabled。
- 清理执行中该项标题变「正在清理…」并禁用，完成后恢复；清理在全局并发队列跑，结果回主队列刷 UI。
- `LoginItem`（`SMAppService.mainApp`，复用 NanoClip 枚举）、`Prefs`（`UserDefaults`：`refreshSeconds`、`balloonMB`；键名 `mb.*`）。

### 6. 打包与安装（`Scripts/`）

- `build-app.sh`：`swift build -c release --product MemBar -Xlinker -dead_strip` → 组装 `build/MemBar.app`（`Info.plist` 含 `LSUIElement=true`、`CFBundleIdentifier=com.jvz.membar`、`LSMinimumSystemVersion=14.0`、category `public.app-category.utilities`）→ `strip -x` → ad-hoc `codesign --force --sign -` → `codesign --verify --strict`。图标由 `GenerateAppIcon.swift` 用 Core Graphics 画圆角底 + 三根渐高柱状条。
- `install.sh`：`pkill -x MemBar` → `rm -rf /Applications/MemBar.app` → `cp -R build/MemBar.app /Applications/` → `open /Applications/MemBar.app`。
- 不写 LaunchAgents、不改系统配置；卸载说明写在 README。

### 7. 代码结构

```
MemBar/
├─ Package.swift                 # MemBarCore(lib) + MemBar(exec) + MemBarCoreTests
├─ README.md                     # 功能/安装/清理原理与限制/内存预算
├─ docs/USAGE.md                 # 菜单逐项说明、故障排查
├─ Sources/MemBarCore/
│   ├─ MemoryStats.swift  MemoryPressure.swift  ProcessScanner.swift
│   ├─ Reclaimer.swift  Balloon.swift  Diagnostics.swift
│   └─ Support/{Log,Prefs,Fmt,AppInfo}.swift
├─ Sources/MemBar/
│   ├─ main.swift
│   └─ App/{AppDelegate,StatusItemController,LoginItem,SingleInstance,Sampler}.swift
├─ Tests/MemBarCoreTests/{PressureTests,StatsMathTests,ProcessFilterTests}.swift
├─ Scripts/{build-app.sh,install.sh,Info.plist,GenerateAppIcon.swift}
└─ Resources/AppIcon.icns        # 构建时生成
```

## 变更影响

- 新增独立工程，不改动 `/Users/jvz/code` 下任何既有项目。
- 用户可见：菜单栏常驻图标与百分比；菜单项如上；`/Applications/MemBar.app`；登录项一条（可在菜单关闭）。
- 需授权的系统能力：无（无辅助功能、无全盘访问、无 root）；`SMAppService` 登录项注册在 ad-hoc 签名下可用，重建后若登录项失效需在菜单里重新勾选（README 说明）。
- 内部 CLI 参数（不对外承诺稳定）：`--diagnostics`、`--balloon <MB>`。

## 测试与验收

单元测试（`swift test`）：

1. `PressureTests`：按 `freeRatio / swapUsed / compressed` 边界构造快照，断言 `normal/elevated/critical` 映射与临界值等号行为。
2. `StatsMathTests`：给固定页数与 `pageSize=16384` 的合成 `vm_statistics64`，断言 `used/cache/free/percent` 数值；`swapTotal=0` 不除零；`used` 不超过 `total`。
3. `ProcessFilterTests`：过滤系统进程/自身/他人 uid，排序与 Top 8 截断正确。

手工验收：

1. `./Scripts/build-app.sh && ./Scripts/install.sh` → 菜单栏出现图标 + 百分比，无 Dock 图标。
2. `--diagnostics` 输出自身 RSS、可用/已用/缓存/压缩/交换、压力等级；与「活动监视器」对照，已用/交换误差 < 10%。
3. 空闲 60 秒采样：RSS ≤ 30 MB，CPU ≤ 0.2%，连续 10 分钟 RSS 稳定。
4. 一键清理：点击后 ≤ 3 秒返回，菜单显示前后对比与耗时；`--diagnostics` 复核 `free+inactive` 未显著下降、`compressed` 增量 ≤ 64 MB、压力等级未变差。**调优规则**：若气球未带来 ≥ 32 MB 可回收提升或压缩量增加超限，把默认 `balloonMB` 降为 64 并在 README 记录实测数据。
5. 勾选一个测试用进程（如自己启动的 `yes > /dev/null`）→「结束选中进程」后该进程消失；未勾选时该按钮 disabled；系统进程不在列表内。
6. 登录项：菜单勾选 → 系统设置 › 通用 › 登录项中出现 MemBar；取消勾选后从列表消失。
7. 双实例：再次 `open -a /Applications/MemBar.app` 不产生第二个图标。
8. 压力分级：用 `--balloon 4096`（诊断用）临时拉高压力量，确认颜色/等级切换，结束后恢复正常。
---

# 执行记录（实现完成后的实测与偏差）

## 差异（相对上文计划）

| 项 | 计划 | 实际 | 原因 |
| --- | --- | --- | --- |
| 压力分级输入 | `freeRatio = free/total` | `availableRatio = (free+inactive+speculative+purgeable)/total` | 实测本机 free/total 仅 0.0089（健康机器通常也 <0.05），会把正常机器一直判成 🔴；改为「可回收比例」后阈值语义仍然成立（<8% 危险、<18% 偏高），纯函数签名 `evaluate(freeRatio:...)` 未变 |
| 默认气球 | 256 MB | **64 MB** | 依计划自身的调优规则：64/128/256 MB 各 3 次实测，freeΔ 中位数 ≈ 0，compressedΔ ≤ ±3 MB → 降为最小档 |
| 内部 CLI 参数 | `--diagnostics`、`--balloon` | 追加 `--clean [MB]`、`--selftest` | 无人值守环境下无法用 AX 点击菜单栏项（`AXExtrasMenuBar` 返回 kAXErrorNoValue），需要可脚本化的验证入口；两者都不出现在菜单里，不改变用户可见行为 |
| 自检驱动方式 | — | `Timer` 状态机（不是 `DispatchQueue.main.async` + 嵌套 RunLoop） | 在 main 队列 block 内跑嵌套 RunLoop 无法排空 main 队列，异步清理/结束进程的完成回调永不执行（已踩坑并修正） |

## 验证证据

| 计划验收项 | 证据 |
| --- | --- |
| `swift test` | 33 个测试全通过（4 个文件：压力边界、换算/除零、进程过滤、结束进程/气球/文案） |
| `./Scripts/build-app.sh && ./Scripts/install.sh` | 构建 + ad-hoc 签名 + `codesign --verify --strict` + 冒烟诊断通过；`/Applications/MemBar.app` 已启动，`pgrep -x MemBar` 单实例 |
| `--diagnostics` 输出 | 打印自身 RSS/线程、已用/缓存/空闲/可回收/压缩/有线、交换、压力 |
| 已用/交换与活动监视器误差 <10% | 交换与 `sysctl vm.swapusage` 同源（误差 0）；已用 11.5 GB vs 活动监视器口径 ≈12.6 GB（App Memory+有线+压缩），差 8.3% |
| RSS ≤30 MB / CPU ≤0.2% / 10 分钟稳定 | footprint 18.1 MB（峰值 19.7）、RSS 78–82 MB（空白 AppKit 基线 78.8 MB）、CPU 0.0%（偶发 0.2%）、10 分钟采样无增长 |
| 一键清理 ≤3 秒返回 + 前后对比 | `--clean` 实测 0.2–0.8 s，结果行与 `clean ...` 日志同时输出；`--selftest` 走 `cleanNow()` 同一路径通过 |
| 气球效果不足时按规则降档 | 见上表「差异」与 README 实测表，默认已降为 64 MB，结果行会写「未获得可回收缓存」 |
| 勾选进程 → 结束后消失；未勾选禁用；系统进程不列出 | `--selftest` 用真实 `sleep` 子进程验证「勾选可用 → 结束成功 → 回到禁用」；单元测试覆盖过滤与「3 秒未退出只报告、不 SIGKILL」 |
| 登录项注册/取消 | 首次启动日志 `login item registered` / `登录项 registered=已启用`；菜单勾选状态来自 `SMAppService.mainApp.status` |
| 双实例 | 直接运行第二个二进制：日志 `second instance detected (pid …); exiting`，`pgrep` 计数保持 1 |
| 压力分级颜色切换 | `--selftest` 用合成「几乎无可回收」快照断言 🔴 紧张 + 红色文字 + 实心图标，随后恢复真实采样 |

## 已知限制

- 压力分级是自定估算规则，不是内核内存压力信号；与活动监视器压力图可能不同档。
- 非特权「一键清理」在 macOS 27 上净收益约等于 0；真正有效的手段是结束进程（菜单已提供，默认不勾选）。
- RSS 含共享 AppKit 页（~80 MB），私有内存以 `vmmap` 的 Physical footprint（18 MB）为准。
