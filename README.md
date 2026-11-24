# MemBar

macOS 菜单栏内存监控 + 一键清理：原生 Swift/AppKit、零第三方依赖、无 Dock 图标、零 root、零辅助功能授权。
只做两件事——**盯着内存**，以及**一键把能还的内存还回去**。

```
🧠 71%   ← 菜单栏实时百分比（紧张时变红）
```

📖 **完整使用说明：[docs/USAGE.md](docs/USAGE.md)**（菜单逐项、清理原理、故障排查）
📋 **实施方案与实测调优记录：[PLAN.md](PLAN.md)**

---

## 功能一览

| 能力 | 说明 |
| --- | --- |
| 内存百分比 | 菜单栏图标旁直接显示 `已用 / 总量`，默认 5 秒刷新（可切 2/5/10 秒） |
| 明细 | 已用 / 空闲 / 可回收 / 缓存 / 压缩 / 有线 / 交换，一行一项 |
| 压力分级 | 🟢 正常 / 🟡 偏高 / 🔴 紧张（基于 vm 统计 + swap 的**估算**，见下文口径） |
| 一键清理 | `⌘K` 或菜单点击：释放自身内存 → 子进程「内存气球」→（可选）结束勾选的高占用进程 |
| 结果回显 | 菜单直接显示 `空闲 A → B（+Δ），缓存 C → D · 用时 N 毫秒`，不谎报效果 |
| 高占用进程 | 只在菜单打开时扫描，列出**你自己**的 Top 8 进程，勾选后 `结束选中进程` |
| 开机自启 | `SMAppService.mainApp` 登录项，首次启动自动注册，菜单里一键开关 |
| 单实例 | 再次启动不会出现第二个图标 |
| 极低占用 | 物理 footprint 17.6 MB，默认 5 秒刷新时空闲 CPU 0.09%，不联网、不写统计文件 |

## 安装（两步）

```bash
./Scripts/build-app.sh      # release 构建 + 打包 .app + 生成图标 + ad-hoc 签名 + 自检诊断
./Scripts/install.sh        # 复制到 /Applications 并启动
```

首次启动后：

1. 菜单栏出现内存芯片图标 + 百分比，**没有** Dock 图标、**不会**弹任何授权框。
2. 自动注册登录项（系统设置 → 通用 → 登录项 → MemBar），菜单里可随时关闭。

> **签名提示**：默认 ad-hoc 签名，重新构建后 cdhash 变化，登录项/系统记录会重新登记，属正常现象。
> 想固定身份可自签名后 `SIGN_IDENTITY="MemBar Local" ./Scripts/build-app.sh`。

## 菜单

```
内存 71% · 已用 11.4 GB / 16 GB
空闲 200 MB · 缓存 3.9 GB · 压缩 4.3 GB
交换 2.8 GB / 4 GB · 🟡 偏高
──────────────
⚡ 一键清理                    ⌘K
上次清理：空闲 490 MB → 440 MB，缓存 3.85 GB → 3.76 GB，未获得可回收缓存 · 用时 789 毫秒 · 12 秒前
高占用进程 ▸
──────────────
刷新间隔 ▸   2 秒 / 5 秒✓ / 10 秒
回收强度 ▸   64 MB✓ / 128 MB / 256 MB / 512 MB
☑ 登录时自动启动
──────────────
退出 MemBar                    ⌘Q
```

## 一键清理做了什么（以及为什么效果有限）

三步，全部无需 root、无需密码：

1. **释放自身内存**：`malloc_zone_pressure_relief(nil, 0)`，本应用几乎不占内存，通常为 0。
2. **内存气球**：`MemBar --balloon <MB>` 子进程临时分配 MB 大小内存并逐页触碰，逼内核回收/压缩其他页，随后 `munmap` 退出。峰值只存在于瞬时子进程，常驻进程 RSS 不膨胀。
3. **结束勾选进程**（可选，默认不勾选）：对 GUI App 用 `NSRunningApplication.terminate()`（可弹保存框），普通进程用 `SIGTERM`；等待 3 秒仍未退出则**只报告「未能结束」，绝不升级 `SIGKILL`**。

### 实测：气球在 macOS 27 上几乎不产生可回收内存

同一台机器（16 GB，compressed 4.3 GB，swap 已用 2.8 GB）连续三次实测 `--clean`，单位为 MB：

| 气球 | run1 freeΔ | run2 freeΔ | run3 freeΔ | compressedΔ |
| --- | --- | --- | --- | --- |
| 256 MB | -0.2 | -212.5 | -8.6 | ≤ ±3 |
| 128 MB | -58.6 | +24.3 | -0.6 | ≤ ±3 |
| 64 MB | -0.4 | +17.9 | -0.1 | ≤ ±3 |

结论：**净收益中位数约 0**（系统本身处于压缩/换页压力下，气球腾出的页很快又被占用）。
按 PLAN 的调优规则，默认气球已从 256 MB 下调为 **64 MB**，选项仍可切到 512 MB；
结果行在无收益时会明确显示 `未获得可回收缓存`，不做虚假宣传。

> 真正能立刻拿回内存的是第 3 步「结束高占用进程」，这也是 macOS 上没有 root 权限时唯一可靠的手段。
> `purge` / `sudo purge` 需要 root，本工具按产品决策**不采用**（不弹密码、不写 sudoers）。

## 内存占用实测

| 指标 | 实测 | 说明 |
| --- | --- | --- |
| 物理 footprint（活动监视器「内存」列） | **17.6 MB**（峰值 19.8 MB） | 私有内存，预算 ≤30 MB ✅ |
| RSS（`ps`） | 76.9 MB | 与空白 AppKit 菜单栏 App 基线（78.8 MB）基本一致，绝大部分是共享的 AppKit 页 |
| 空闲 CPU（默认 5 秒刷新） | **0.09%**（10 分钟 60 次采样的平均值，峰值 1.6%） | 预算 ≤0.2% ✅ |
| 空闲 CPU（2 秒刷新） | 0.72% | 每次菜单栏文字变化约 20 ms（WindowServer 往返）；固定宽度状态栏项 + 仅在百分比变化时重绘已把代价压到最低 |
| 10 分钟 RSS 波动 | 76.9 MB → 44.0 MB（系统在内存压力下回收干净页所致，**无增长趋势**） | 无泄漏（10 s × 60 次采样） |
| `--diagnostics`（无界面）RSS | 6.4 MB | 只跑 syscall 时的净占用 |

测量方式与原始数据见 [docs/USAGE.md#性能实测](docs/USAGE.md)。

## 内部诊断参数（不作为稳定接口）

| 参数 | 作用 |
| --- | --- |
| `--diagnostics` | 打印一次采样（自身 RSS/线程、已用/缓存/空闲/可回收/压缩/有线、交换、压力），退出 |
| `--clean [MB]` | 用与「一键清理」完全相同的流水线跑一次（不结束进程），打印清理前后与结果文案 |
| `--balloon <MB>` | 只跑内存气球子进程（清理流程会自己调用它） |
| `--selftest` | 启动 UI 并自检：菜单栏可见性与文字、菜单结构/文案/enabled 状态、压力红色渲染、刷新间隔/回收强度切换、一键清理、结束进程、登录项注册-注销往返、偏好读写；输出 `自检结果: OK` 并以 0 退出 |

## 测试

```bash
swift test        # 33 个单元测试：压力分级边界、换算与除零、进程过滤、结束进程、气球、结果文案
./build/MemBar.app/Contents/MacOS/MemBar --selftest   # UI + 清理流水线端到端自检
```

## 代码结构

```
MemBar/
├─ Package.swift                     # MemBarCore(lib) + MemBar(exec) + MemBarCoreTests
├─ Sources/MemBarCore/
│  ├─ MemoryStats.swift              # host_statistics64 + sysctl，纯值快照
│  ├─ MemoryPressure.swift           # normal/elevated/critical 规则
│  ├─ ProcessScanner.swift           # proc_listallpids/proc_pidinfo，只扫自己的进程
│  ├─ Reclaimer.swift                # 一键清理流水线与结果文案
│  ├─ Balloon.swift                  # --balloon 子进程
│  ├─ Diagnostics.swift              # --diagnostics / --clean
│  └─ Support/{AppInfo,Log,Prefs,Fmt}.swift
├─ Sources/MemBar/
│  ├─ main.swift                     # 参数分流（balloon/clean/diagnostics/selftest）
│  └─ App/{AppDelegate,StatusItemController,Sampler,LoginItem,SingleInstance}.swift
├─ Tests/MemBarCoreTests/            # 4 个测试文件
├─ Scripts/{build-app.sh,install.sh,Info.plist,GenerateAppIcon.swift}
└─ Resources/AppIcon.icns            # 构建时生成
```

## 卸载

```bash
osascript -e 'quit app "MemBar"'
rm -rf /Applications/MemBar.app
rm -f ~/Library/Logs/MemBar.log ~/Library/Logs/MemBar.log.1
defaults delete com.jvz.membar
# 登录项：菜单取消勾选（或在 系统设置 → 通用 → 登录项 里移除）
```

## 口径与限制

- **已用** = `active + wired + compressed`，**缓存** = `inactive + speculative + purgeable`，**空闲** = `free + speculative`，**可回收** = `free + inactive + speculative + purgeable`；交换直接取 `sysctl vm.swapusage`（与活动监视器同源）。
  已用口径与活动监视器「已用内存」相近（本机 11.5 GB vs 活动监视器口径 ≈12.6 GB，差额 <10%），但文件缓存归属略有差异。
- **压力分级是估算**，不等于活动监视器内存压力图：🔴 可回收 <8% 或 swap >4 GB；🟡 可回收 <18% 或 swap >1 GB 或压缩 >25% 物理内存；其余 🟢。
- 只会结束**当前用户自己的**进程；系统进程（`kernel_task`、`WindowServer`、`Dock`、`Finder`、`mds*`、`cfprefsd` 等）与 `pid < 100` 一律不列出、不触碰。
- 不联网、不落盘统计数据；日志只有生命周期与清理记录（`~/Library/Logs/MemBar.log`，超 256 KB 自动轮转一次）。