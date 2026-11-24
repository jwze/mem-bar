# MemBar 使用说明

> 目标：**看内存**（菜单栏实时百分比）＋ **一键清理**（非特权回收 + 可选结束高占用进程）。
> 不联网、不要 root、不要辅助功能授权、不写统计数据。

- [1. 安装与首次启动](#1-安装与首次启动)
- [2. 菜单逐项说明](#2-菜单逐项说明)
- [3. 一键清理的原理与预期](#3-一键清理的原理与预期)
- [4. 刷新间隔 / 回收强度 / 登录项](#4-刷新间隔--回收强度--登录项)
- [5. 性能实测](#5-性能实测)
- [6. 故障排查](#6-故障排查)
- [7. 卸载](#7-卸载)

---

## 1. 安装与首次启动

```bash
cd /path/to/MemBar
./Scripts/build-app.sh     # release 构建 + 组装 .app + 生成图标 + ad-hoc 签名 + 冒烟诊断
./Scripts/install.sh       # 关掉旧实例 → 复制到 /Applications/MemBar.app → 启动
```

| 需求 | 说明 |
| --- | --- |
| 系统版本 | macOS 14 或更高（开发/实测环境 macOS 27.2.1，Swift 6.4） |
| 依赖 | 无第三方依赖；`swift build` 需要 Xcode 或 Command Line Tools |
| 授权 | **不需要任何授权**（无辅助功能、无全盘访问、无 root） |

首次启动后会发生什么：

1. 菜单栏出现一个内存芯片图标 + 百分比（例：`🧠 71%`）；Dock 里没有图标。
2. 首次启动（且 App 已位于 `/Applications`）会自动注册登录项；`SMAppService` 状态下菜单会打勾。
3. 日志文件在 `~/Library/Logs/MemBar.log`，只有启动、清理、登录项变更三类记录。

验证安装：

```bash
pgrep -x MemBar                                     # 应有一个 pid
/Applications/MemBar.app/Contents/MacOS/MemBar --diagnostics   # 打印一次采样后退出
```

## 2. 菜单逐项说明

```
内存 71% · 已用 11.4 GB / 16 GB          ← 汇总行（不可点击）
空闲 200 MB · 缓存 3.9 GB · 压缩 4.3 GB    ← 明细（不可点击）
交换 2.8 GB / 4 GB · 🟡 偏高              ← 交换用量 + 压力估值
──────────────
⚡ 一键清理                    ⌘K
上次清理：空闲 490 MB → 440 MB，缓存 3.85 GB → 3.76 GB，
         未获得可回收缓存 · 用时 789 毫秒 · 12 秒前
高占用进程 ▸
──────────────
刷新间隔 ▸  2 秒 / 5 秒✓ / 10 秒
回收强度 ▸  64 MB✓ / 128 MB / 256 MB / 512 MB
☑ 登录时自动启动
──────────────
退出 MemBar                    ⌘Q
```

| 菜单项 | 说明 |
| --- | --- |
| 内存 x% · 已用 / 总量 | `已用 = active + wired + compressed`，百分比**向上取整**（0.1% 也不会显示 0%） |
| 空闲 / 缓存 / 压缩 | `空闲 = free + speculative`；`缓存 = inactive + speculative + purgeable`；压缩=压缩器占用的物理页 |
| 交换 a / b · 🟢🟡🔴 | `sysctl vm.swapusage`，与活动监视器同源；压力等级是**估算值** |
| ⚡ 一键清理 | 执行清理流水线；执行中标题变为 `正在清理…` 且禁用，结束后恢复 |
| 上次清理 | 最近一次清理（或最近一次「结束选中进程」/「登录项未生效」）的结果与相对时间 |
| 高占用进程 ▸ | **只在菜单打开时**扫描一次；列出当前用户 RSS 最大的 8 个进程 |
| 结束选中进程 (N) | 仅在勾选 ≥1 项时可用；未勾选时禁用 |
| 刷新间隔 | 2 / 5 / 10 秒，改动立即生效并持久化 |
| 回收强度 | 内存气球大小，默认 64 MB（见第 3 节实测） |
| 登录时自动启动 | `SMAppService.mainApp`，勾选=注册，取消=注销 |
| 退出 MemBar | 结束进程（登录项状态保留） |

压力分级（估算）：

| 等级 | 条件 |
| --- | --- |
| 🔴 紧张 | 可回收 < 8% 物理内存 **或** swap 已用 > 4 GB |
| 🟡 偏高 | 可回收 < 18% **或** swap 已用 > 1 GB **或** 压缩 > 25% 物理内存 |
| 🟢 正常 | 以上都不满足 |

紧张时：菜单栏图标换成 `memorychip.fill`，百分比文字变**红色加粗**。

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
- 结束方式：GUI App 用 `NSRunningApplication.terminate()`（有未保存文档时会弹保存框），普通进程用 `SIGTERM`；**等 3 秒仍未退出就报告「未能结束」，不会 `SIGKILL`**。

## 3. 一键清理的原理与预期

执行顺序（任一步失败只记录，不中断）：

1. **释放自身内存** `malloc_zone_pressure_relief(nil, 0)` —— MemBar 自身通常只占 18 MB，这一步多半是 0。
2. **内存气球**：`MemBar --balloon <MB>` 子进程 `mmap` 一块匿名内存，按 8 MB 分段 `memset` 逐页触碰（段间 `usleep 20ms` 让内核有机会回收），然后 `munmap` 退出；3 秒超时会 `SIGKILL` 子进程。常驻进程的 RSS 不受影响。
3. **结束勾选进程**（默认没有勾选项 → 跳过）。

然后取清理后快照，生成结果行，并写入日志：

```
2026-11-24 14:53:01 [INFO] clean balloon=64MB ran=true
  free=452476928→436518912 cache=4367040512→4407427072 compressed=4475076608→4471685120
  stress=elevated→elevated selfRelief=0 terminated=[] stuck=[] reclaimed=no duration=0.79s
```

### 期望值（实测，别抱太高期望）

在同一台 16 GB / 压缩 4.3 GB / swap 已用 2.8 GB 的机器上各跑 3 次：

| 气球 | freeΔ（MB） | compressedΔ（MB） | 耗时 |
| --- | --- | --- | --- |
| 64 MB | -0.4 / +17.9 / -0.1 | ≈ 0 | ~0.2–0.8 s |
| 128 MB | -58.6 / +24.3 / -0.6 | ≈ 0 | ~0.5 s |
| 256 MB | -0.2 / -212.5 / -8.6 | ≤ ±3 | ~0.8 s |

**结论：气球带来的净回收中位数约为 0。** 系统处于压缩/换页压力下时，腾出的页几乎立刻被重新使用。
因此默认值已按 PLAN 的调优规则从 256 MB 降为 **64 MB**；没有收益时结果行会明确写 `未获得可回收缓存`。

要真正拿回内存，用「高占用进程」结束不用的 App（第 3 步），这是无 root 环境下唯一可靠的手段。
`purge`（需要 root，通常要 `sudo`）按产品决策**未采用**：不弹管理员密码框、不写 sudoers。

## 4. 刷新间隔 / 回收强度 / 登录项

- **刷新间隔**：`UserDefaults` 键 `mb.refreshSeconds`（2/5/10）。每次 tick 只做 1 次 `host_statistics64` + 2 次 `sysctlbyname`，几百纳秒级。
- **回收强度**：键 `mb.balloonMB`（64/128/256/512）。数值越大，子进程瞬时占用越大，但实测收益并不随之提升。
- **登录项**：`SMAppService.mainApp`。如果显示「需在系统设置允许」，请在 系统设置 → 通用 → 登录项 里打开；
  显示「请先安装到 /Applications」说明 App 还在 build 目录（`SMAppService` 只对已安装位置生效）。

重置所有偏好：

```bash
defaults delete com.jvz.membar
```

## 5. 性能实测

环境：macOS 27.2.1（build 26B131）、Apple Silicon、16 GB。

### 5.1 常驻占用

```bash
ps -o rss=,%cpu= -p $(pgrep -x MemBar)     # RSS / CPU
vmmap -summary $(pgrep -x MemBar) | grep "Physical footprint"
```

| 指标 | 实测值 | 预算 | 结论 |
| --- | --- | --- | --- |
| 物理 footprint | 17.6 MB（峰值 19.8 MB） | ≤ 30 MB | ✅ |
| RSS | 76.9 MB（稳定段 76.8–77.7 MB） | — | 与空白 AppKit 菜单栏 App 基线 78.8 MB 持平（几乎全是共享 AppKit 页） |
| 空闲 CPU（默认 5 秒刷新） | 0.09%（10 分钟 60 次采样平均，峰值 1.6%） | ≤ 0.2% | ✅ |
| 空闲 CPU（2 秒刷新） | 0.72% | — | 每次菜单栏文字变化约 20 ms（WindowServer 往返），刷新越快越费 CPU |
| 10 分钟 RSS 漂移 | 76.9 → 44.0 MB（末段下降=系统回收干净页），无上升趋势 | 无泄漏 | ✅ |
| `--diagnostics` 净 RSS | 6.4 MB | — | 纯 syscall 模式的净占用 |

> RSS 把共享库的只读页也算进去，所以会看到 ~77 MB；`vmmap` 的 **Physical footprint** 才是活动监视器「内存」列的口径，也就是真正属于 MemBar 的 17.4 MB。

CPU 优化的三个实现细节（都在 `StatusItemController` 里）：

1. 状态栏项使用**固定宽度**（64 pt）：`variableLength` 会在每次字数变化时让 WindowServer 重新排版整条菜单栏。
2. 菜单栏文字**只在「百分比取整值」或压力等级变化时**才重绘（`renderedPercent/renderedPressure` 缓存）；tooltip 与数字同步重建，不在每个采样 tick 上重算。
3. 明细行（已用/缓存/交换/结果行）只在**菜单打开时**重建，5 秒 tick 只做一次 syscall 采样 + 一次可能的重绘。

### 5.2 数值对照

```bash
/Applications/MemBar.app/Contents/MacOS/MemBar --diagnostics
sysctl vm.swapusage      # 交换：与 MemBar 显示完全一致（同源）
vm_stat                  # 页计数原值
```

- 交换：MemBar 直接用 `sysctl vm.swapusage`，与活动监视器同源，误差 0。
- 已用：本机 MemBar 11.5 GB；活动监视器口径（App Memory 5.1 GB + 有线 3.1 GB + 压缩 4.4 GB）≈ 12.6 GB，差额 < 10%（文件缓存归类差异）。
- 压力：MemBar 显示 🟡 偏高（swap 2.8 GB > 1 GB，压缩 4.4 GB > 25%）；`memory_pressure` 报 "System-wide memory free percentage: 52%"。**两者口径不同**，MemBar 的分级是自定的估算规则，不是内核信号。

### 5.3 自检（端到端）

```bash
./build/MemBar.app/Contents/MacOS/MemBar --selftest
```

检查项（全部通过时输出 `自检结果: OK（0 项失败）` 并以 0 退出）：

| 检查 | 证据 |
| --- | --- |
| 菜单栏项可见 | `statusItem.isVisible=true` + 按钮帧位于菜单栏 |
| 菜单结构/文案/enabled | 逐项打印标题与状态；摘要/交换/结果行非空，⌘K/⌘Q 存在，子菜单数量正确，未勾选时「结束选中进程」禁用 |
| 紧张态渲染 | 合成「几乎无可回收」快照 → 断言 🔴 紧张、文字为 `NSColor.systemRed`、图标为 `memorychip.fill`，随后恢复真实采样 |
| 刷新间隔/回收强度切换 | 切到 2 秒/128 MB 再切回原值，断言 `sampler.interval`、勾选态、`UserDefaults` 都随之变化 |
| 一键清理 | 走 `cleanNow()` 同一路径，等待真实流水线结束并断言结果行已更新 |
| 结束进程 | 启动真实 `sleep` 子进程 → 勾选 → 结束 → 断言进程消失、按钮回到禁用 |
| 登录项往返 | 仅在 `/Applications` 下执行：注销 → 断言状态非 enabled → 重新注册 → 断言恢复 |
| 偏好读写 | 恢复原值后读回比对 |

## 6. 故障排查

| 现象 | 处理 |
| --- | --- |
| 菜单栏没有图标 | 确认 `pgrep -x MemBar`；若已有进程，先 `osascript -e 'quit app "MemBar"'` 再启动；菜单栏项太多时可能被系统隐藏 |
| 再次启动没反应 | 这是单实例保护：第二个实例会激活已有实例并退出（日志 `second instance detected`） |
| 百分比不动 | 检查菜单「刷新间隔」是否被设为 10 秒；系统内存极度紧张时定时器可能被延迟 |
| 一键清理后数字没变好 | 预期行为：非特权回收基本无效，见第 3 节；请用「高占用进程」结束不用的 App |
| 「结束选中进程」灰色 | 没有勾选任何进程；勾选后标题会变成 `结束选中进程 (1)` |
| 结束进程后提示「未能结束」 | 该 App 拒绝退出（例如有未保存文档/正在弹窗）；MemBar 不会强杀 |
| 登录项打勾但重启后没有图标 | 系统设置 → 通用 → 登录项 里确认 MemBar 处于允许状态；ad-hoc 重建后可能需重新勾选 |
| 想找回内存但不想结束 App | 只能等系统自己回收（关闭窗口、退出后台 App），本工具不会碰别人的内存 |
| 图标一直是红色的 | 说明可回收内存 < 8% 或 swap > 4 GB；此时结束大进程或重启更有效 |

日志（只有生命周期与清理记录）：

```bash
tail -20 ~/Library/Logs/MemBar.log
```

## 7. 卸载

```bash
osascript -e 'quit app "MemBar"'          # 或菜单「退出 MemBar」
rm -rf /Applications/MemBar.app
rm -f ~/Library/Logs/MemBar.log ~/Library/Logs/MemBar.log.1
defaults delete com.jvz.membar
```

登录项：卸载前在菜单里取消「登录时自动启动」（或 系统设置 → 通用 → 登录项 里移除，系统会提示残留项已失效）。
源码与构建产物可直接删除 `MemBar/` 目录（`.build/`、`build/`、`Resources/AppIcon.icns` 均已在 `.gitignore`）。