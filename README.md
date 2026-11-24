# MemBar

macOS 菜单栏内存监控 + 一键清理。原生 Swift / AppKit，零第三方依赖，无 Dock 图标，不要 root，不要辅助功能授权。

```
 ╭──────╮  ╭──────╮  ╭──────╮
 │ 41%  │  │ 71%  │  │ 93%  │   ← 圆角胶囊，颜色随压力等级变化
 ╰──────╯  ╰──────╯  ╰──────╯
   绿         黄         红
```

菜单栏项是**自绘固定宽度徽章**（45×18 pt，按 `100%` 定宽）：压力色胶囊 + 白色等宽数字，2× 位图渲染保证 Retina 清晰，图片按 `(百分比, 等级)` 缓存，只在取整百分比或压力等级变化时重绘。

- **看内存**：菜单栏实时百分比；点开是「大号百分比 + 内存构成条 + 右对齐数值列」的明细卡片。
- **一键清理**：`⌘K` 释放自身内存 → 内存气球子进程 →（可选）结束勾选的应用，并如实回显结果。

📖 **完整使用教程：[docs/USAGE.md](docs/USAGE.md)**

---

## 功能一览

| 能力 | 说明 |
| --- | --- |
| 内存百分比 | 菜单栏胶囊徽章，压力色 + 等宽数字，默认 5 秒刷新（可切 2/5/10 秒） |
| 明细卡片 | 大号压力色百分比 + 三段构成条（已用/缓存/空闲）+ 数值右对齐成列 |
| 压力分级 | 🟢 正常 / 🟡 偏高 / 🔴 紧张（基于 vm 统计 + swap 的**估算**，见下文口径） |
| 一键清理 | `⌘K`：释放自身内存 → 子进程「内存气球」→（可选）结束勾选的应用 |
| 结果回显 | 直接显示 `空闲 A → B（+Δ），缓存 C → D · 用时 N 毫秒`，不谎报效果 |
| 高占用进程 | 只在菜单打开时扫描，**按应用聚合**（Chrome 的 7 个 helper 只占一行） |
| 开机自启 | `SMAppService.mainApp` 登录项，首次启动自动注册，菜单里一键开关 |
| 单实例 | 再次启动不会出现第二个图标 |
| 极低占用 | 物理 footprint ≈17 MB，默认 5 秒刷新时空闲 CPU ≈0%，不联网、不写统计文件 |

## 快速开始

```bash
./Scripts/build-app.sh      # release 构建 + 打包 .app + 生成图标 + ad-hoc 签名 + 冒烟诊断
./Scripts/install.sh        # 复制到 /Applications 并启动
```

要求：macOS 14+、Xcode 或 Command Line Tools（提供 `swift`）。

首次启动后菜单栏出现徽章，**没有** Dock 图标，**不会**弹任何授权框，并自动注册登录项（菜单里可随时关闭）。

## 菜单

```
70%   11.08 GB / 16 GB              ← 大号压力色百分比 + 已用/总量
███████████████░░░░░░░░░            ← 构成条：黑=已用 蓝=缓存 青=空闲
● 已用 11.08 GB  ● 缓存 4.45 GB  ● 空闲 245 MB
──────────────────────────
已用 · 🟡 偏高        11.08 GB       ← 数值右对齐成一列
缓存                   4.45 GB
压缩                   3.56 GB
交换 · 已用 71.8%   2.87 GB / 4 GB
──────────────────────────
⚡ 一键清理                  ⌘K
上次清理：空闲 490 MB → 862 MB · 用时 1.7 秒 · 12 秒前
高占用进程 ▸
──────────────────────────
刷新间隔 ▸   2 秒 / 5 秒✓ / 10 秒
☑ 登录时自动启动
──────────────────────────
退出 MemBar                  ⌘Q
```

### 高占用进程：按应用聚合

```
WeChat  ·16                          723.8 MB
node  ·7                             635.1 MB
IntelliJ IDEA  ·2                    426.8 MB
Google Chrome  ·7                    413.7 MB
──────────────────────────
结束选中应用 (0)
```

同一个 `.app` 的全部进程（渲染器 / GPU / Helper）合并成一行、尺寸相加，避免一个浏览器把 Top 8 全占满；
后缀 `·N` 是折叠的进程数，名字取自 `.app` 包名，所以是 `IntelliJ IDEA` 而不是 `idea`。
勾选一行 = 勾选整个应用。

## 一键清理做了什么（以及为什么效果有限）

三步，全部无需 root、无需密码：

1. **释放自身内存**：`malloc_zone_pressure_relief(nil, 0)`，本应用占用很小，通常为 0。
2. **内存气球**：`MemBar --balloon 64` 子进程临时分配内存并逐页触碰，逼内核回收/压缩其他页，随后 `munmap` 退出。峰值只存在于瞬时子进程，常驻进程 RSS 不膨胀。
3. **结束勾选应用**（可选，默认不勾选）：GUI App 用 `NSRunningApplication.terminate()`（可弹保存框），普通进程用 `SIGTERM`；等待 3 秒仍未退出则**只报告「未能结束」，绝不升级 `SIGKILL`**。

### 实测：气球在 macOS 27 上几乎不产生可回收内存

同一台机器（16 GB，compressed 4.3 GB，swap 已用 2.8 GB）连续三次实测 `--clean`，单位为 MB：

| 气球 | run1 freeΔ | run2 freeΔ | run3 freeΔ | compressedΔ |
| --- | --- | --- | --- | --- |
| 256 MB | -0.2 | -212.5 | -8.6 | ≤ ±3 |
| 128 MB | -58.6 | +24.3 | -0.6 | ≤ ±3 |
| 64 MB | -0.4 | +17.9 | -0.1 | ≤ ±3 |

结论：**净收益中位数约 0**，所以气球固定为 **64 MB** 且**不再提供「回收强度」调节**（调大档位并不提升收益，只会让人误以为有用）。
结果行在无收益时会明确显示 `未获得可回收缓存`，不做虚假宣传。

> 真正能立刻拿回内存的是第 3 步「结束高占用应用」，这也是 macOS 上没有 root 权限时唯一可靠的手段。
> `purge` / `sudo purge` 需要 root，本工具按产品决策**不采用**（不弹密码、不写 sudoers）。

## 目录结构

```
MemBar/
├─ Package.swift                     # SwiftPM：MemBarCore(库) + MemBar(可执行)
├─ Scripts/
│  ├─ build-app.sh                   # 构建 → 组装 .app → 图标 → 签名 → 冒烟诊断
│  ├─ install.sh                     # 安装到 /Applications 并启动
│  ├─ GenerateAppIcon.swift          # 生成 Resources/AppIcon.icns（构建时按需调用）
│  └─ Info.plist                     # App Bundle 元数据（LSUIElement=true）
└─ Sources/
   ├─ MemBarCore/                    # 纯逻辑，无 UI，可单独复用
   │  ├─ MemoryStats.swift           # host_statistics64 + sysctl 快照
   │  ├─ MemoryPressure.swift        # 🟢/🟡/🔴 分级规则
   │  ├─ ProcessScanner.swift        # proc_listallpids / proc_pidinfo，按 .app 聚合
   │  ├─ Reclaimer.swift             # 一键清理流水线与结果文案
   │  ├─ Balloon.swift               # --balloon 子进程
   │  ├─ Diagnostics.swift           # --diagnostics / --clean
   │  └─ Support/{AppInfo,Log,Prefs,Fmt}.swift
   └─ MemBar/                        # AppKit 外壳
      ├─ main.swift                  # 参数分流（balloon / clean / diagnostics / selftest）
      └─ App/{AppDelegate,StatusItemController,MenuStyle,MenuBarBadge,
              Sampler,LoginItem,SingleInstance}.swift
```

## 常用命令

```bash
swift build -c release                                   # 只编译
./Scripts/build-app.sh                                   # 产出 build/MemBar.app
./build/MemBar.app/Contents/MacOS/MemBar --diagnostics    # 打印一次采样后退出
./build/MemBar.app/Contents/MacOS/MemBar --clean 128      # 跑一次清理流水线（不结束进程）
./build/MemBar.app/Contents/MacOS/MemBar --selftest       # UI + 清理流水线端到端自检
```

## 卸载

```bash
osascript -e 'quit app "MemBar"'
rm -rf /Applications/MemBar.app
rm -f ~/Library/Logs/MemBar.log ~/Library/Logs/MemBar.log.1
defaults delete com.jvz.membar
```

## 口径与限制

- **已用** = `active + wired + compressed`，**缓存** = `inactive + speculative + purgeable`，**空闲** = `free + speculative`；交换取 `sysctl vm.swapusage`（与活动监视器同源）。
- **压力分级是估算**，不是内核信号：🔴 可回收 <8% 或 swap >4 GB；🟡 可回收 <18% 或 swap >1 GB 或压缩 >25% 物理内存；其余 🟢。
- 只结束**当前用户自己的**进程；系统进程与 `pid < 100` 一律不列出、不触碰，且从不 `SIGKILL`。
- 进程大小口径是 **RSS**（`pti_resident_size`），与活动监视器「内存」列的 footprint 口径略有差异。
- 不联网、不落盘统计数据；日志只有生命周期与清理记录（`~/Library/Logs/MemBar.log`，超 256 KB 轮转一次）。
