# MemBar

macOS 菜单栏内存监控 + 一键清理。原生 Swift / AppKit，零第三方依赖，无 Dock 图标，不要 root，不要辅助功能授权。
```
 ╭──────╮  ╭──────╮  ╭──────╮
 │ 41%  │  │ 71%  │  │ 93%  │   ← 圆角胶囊，颜色随压力等级变化
 ╰──────╯  ╰──────╯  ╰──────╯
   绿         黄         红
```

菜单栏项是**自绘固定宽度徽章**（45×18 pt，按 `100%` 定宽）：压力色胶囊 + 白色等宽数字，2× 位图渲染保证 Retina 清晰，图片按 `(百分比, 等级)` 缓存，只在取整百分比或压力等级变化时重绘。

- **看内存**：菜单栏实时百分比，菜单里给出空闲 / 缓存 / 压缩 / 交换 / 压力分级。
- **一键清理**：`⌘K` 释放自身内存 → 内存气球子进程 →（可选）结束勾选的高占用进程，并如实回显结果。

📖 **完整使用教程：[docs/USAGE.md](docs/USAGE.md)**

---

## 快速开始

```bash
./Scripts/build-app.sh      # release 构建 + 打包 .app + 生成图标 + ad-hoc 签名 + 冒烟诊断
./Scripts/install.sh        # 复制到 /Applications 并启动
```

要求：macOS 14+、Xcode 或 Command Line Tools（提供 `swift`）。

首次启动后菜单栏出现内存芯片图标 + 百分比，**没有** Dock 图标，**不会**弹任何授权框，并自动注册登录项（菜单里可随时关闭）。

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
   │  ├─ ProcessScanner.swift        # proc_listallpids / proc_pidinfo，只扫当前用户进程
   │  ├─ Reclaimer.swift             # 一键清理流水线与结果文案
   │  ├─ Balloon.swift               # --balloon 子进程
   │  ├─ Diagnostics.swift           # --diagnostics / --clean
   │  └─ Support/{AppInfo,Log,Prefs,Fmt}.swift
   └─ MemBar/                        # AppKit 外壳
      ├─ main.swift                  # 参数分流（balloon / clean / diagnostics / selftest）
      └─ App/{AppDelegate,StatusItemController,MenuBarBadge,Sampler,LoginItem,SingleInstance}.swift
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
- 非特权回收（内存气球）实测净收益中位数约为 0，结果行会明确显示 `未获得可回收缓存`，不做虚假宣传。
- 不联网、不落盘统计数据；日志只有生命周期与清理记录（`~/Library/Logs/MemBar.log`，超 256 KB 轮转一次）。
