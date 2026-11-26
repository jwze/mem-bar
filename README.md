# MemBar

macOS 菜单栏内存监控 + 一键清理。原生 Swift / AppKit，零第三方依赖，无 Dock 图标，不要 root，不要辅助功能授权。

```
 ╭──────╮  ╭──────╮  ╭──────╮
 │ 41%  │  │ 71%  │  │ 93%  │   ← 圆角胶囊，颜色随压力等级变化
 ╰──────╯  ╰──────╯  ╰──────╯
   绿         黄         红
```

菜单栏项是**自绘固定宽度徽章**（45×18 pt，按 `100%` 定宽）：压力色胶囊 + 白色等宽数字，2× 位图渲染保证 Retina 清晰，图片按 `(百分比, 等级)` 缓存，只在取整百分比或压力等级变化时重绘。

- **看内存**：菜单栏实时百分比；点开是一张**统一面板卡片**：大号压力色百分比 + 压力胶囊 + 内存构成条 + 右对齐数值列。
- **一键清理**：面板里唯一的**醒目实心按钮**（`⌘K`）：释放自身内存 → 内存气球子进程 →（可选）结束勾选的应用，并如实回显结果。
- **不灰化**：只读区域（数字、图例、结果行）全部满对比度绘制，不用灰度也不降透明度 —— 禁用的系统菜单项会被 AppKit 自动灰化，所以信息区改由自绘视图承载。

📖 **完整使用教程：[docs/USAGE.md](docs/USAGE.md)**

---

## 功能一览

| 能力 | 说明 |
| --- | --- |
| 内存百分比 | 菜单栏胶囊徽章，压力色 + 等宽数字，默认 5 秒刷新（可切 2/5/10 秒） |
| 明细卡片 | 一张自绘卡片：大号压力色百分比 + 压力胶囊 + 三段构成条 + 数值右对齐成列，全部满对比度 |
| 醒目按钮 | 面板中唯一的实心强调色按钮，白字 + `⌘K` 提示，悬停/按下都有反馈 |
| 压力分级 | 🟢 正常 / 🟡 偏高 / 🔴 紧张（基于 vm 统计 + swap 的**估算**，见下文口径） |
| 一键清理 | `⌘K`：释放自身内存 → 子进程「内存气球」→（可选）结束勾选的应用 |
| 结果回显 | 只报一句实话：`已释放 297 MB` 或 `无可释放缓存`（完整 before/after 进日志），不谎报效果 |
| 高占用应用 | 只在弹窗打开时扫描，**按应用聚合**（Chrome 的 7 个 helper 只占一行） |
| 开机自启 | `SMAppService.mainApp` 登录项，首次启动自动注册，面板里一键开关 |
| 单实例 | 再次启动不会出现第二个图标 |
| 极低占用 | 物理 footprint ≈17 MB，默认 5 秒刷新时空闲 CPU ≈0%，不联网、不写统计文件 |

## 快速开始

```bash
./Scripts/build-app.sh      # release 构建 + 打包 .app + 图标 + ad-hoc 签名 + 冒烟诊断（60 秒硬超时）
./Scripts/install.sh        # 复制到 /Applications 并启动
```

要求：macOS 14+、Xcode 或 Command Line Tools（提供 `swift`）。

## GitHub Actions 构建与发布

GitHub Actions 会在向 `main` 推送或创建 Pull Request 时构建并运行冒烟诊断；构建产物 `MemBar.zip` 可在对应的 Actions 运行记录中下载。推送版本标签（例如 `v1.0.0`）会在构建通过后自动创建 GitHub Release，并附上该安装包：

```bash
git tag v1.0.0
git push origin v1.0.0
```

`build-app.sh` 每一步都在 60 秒总预算内运行：任何一步超时就判**构建失败**并杀掉整棵进程树（`BUILD_TIMEOUT=120` 可放宽）。

首次启动后菜单栏出现徽章，**没有** Dock 图标，**不会**弹任何授权框，并自动注册登录项（面板里可随时关闭）。

## 面板（点菜单栏徽章）

```
 67%   已用 10.62 GB / 16 GB        ╭──────╮
 ████████████████░░░░░░░░░░         │ 偏高 │  ← 压力胶囊，与菜单栏徽章同色
 ● 已用    ● 缓存    ● 空闲          ╰──────╯
 ──────────────────────────────────────
 缓存                              4.55 GB
 空闲                             376.7 MB
 压缩                              2.92 GB
 交换 · 已用 65.4%           1.96 GB / 3 GB
 ┌────────────────────────────────────┐
 │           ⚡ 一键清理    ⌘K         │   ← 唯一的醒目实心按钮
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

### 高占用应用：按应用聚合（面板第二页）

```
‹ 返回                          8 个应用 · 共 4.27 GB
Google Chrome        ███████░░░░░░░░   1.3 GB
WeChat               ████████░░░░░░░   1.04 GB
Qoder CN             ███░░░░░░░░░░░░   778.1 MB
node                 █░░░░░░░░░░░░░░   352 MB
──────────────────────────────────────────────
结束选中应用 (2)                    ← 勾选后才出现，窗口同时长高
```

一行一应用，中间一列条形是「占最大那一行」的比例。没有复选框，点整行就是勾选；勾选后名字加粗
并铺一层浅强调色底。没勾选时**没有按钮也没有提示语**，卡片到最后一个应用就结束；勾选第一个应用
后按钮出现、弹窗高度同步变化，不会用按钮盖住列表。

同一个 `.app` 的全部进程（渲染器 / GPU / Helper）合并成一行、尺寸相加，避免一个浏览器把 Top 8 全占满；
名字取自 `.app` 包名，所以是 `IntelliJ IDEA` 而不是 `idea`。勾选一行 = 勾选整个应用。

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
│  ├─ build-app.sh                   # 构建 → 组装 .app → 图标 → 签名 → 冒烟诊断（60 s 上限）
│  ├─ timeout.sh                     # 构建步骤的硬超时（macOS 没有 coreutils timeout）
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
      └─ App/{AppDelegate,StatusItemController,PanelSheetView,
              PanelCardView,PanelRowCards,MenuStyle,MenuBarBadge,
              Sampler,LoginItem,SingleInstance}.swift
```

## 常用命令

```bash
swift build -c release                                   # 只编译
./Scripts/build-app.sh                                   # 产出 build/MemBar.app
./build/MemBar.app/Contents/MacOS/MemBar --diagnostics    # 打印一次采样后退出
./build/MemBar.app/Contents/MacOS/MemBar --clean 128      # 跑一次清理流水线（不结束进程）
./build/MemBar.app/Contents/MacOS/MemBar --selftest       # UI + 清理流水线端到端自检（55 s 上限，必定退出）
./build/MemBar.app/Contents/MacOS/MemBar --preview /tmp/x  # 把三张卡片渲染成 PNG，便于比对 UI
BUILD_TIMEOUT=120 ./Scripts/build-app.sh                  # 放宽构建超时（默认 60 s）
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
