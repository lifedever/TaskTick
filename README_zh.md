# TaskTick

<p align="center">
  <img src="docs/icon.svg" width="128" height="128" alt="TaskTick Icon">
</p>

<p align="center">
  <strong>macOS 原生定时任务管理，开箱即用，菜单栏常驻。</strong>
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases">下载</a> ·
  <a href="https://lifedever.github.io/TaskTick/">官网</a> ·
  <a href="https://lifedever.github.io/sponsor/">赞助</a>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-15-22.51.43@2x.png" width="800" alt="TaskTick 截图">
</p>

## 功能特色

- **菜单栏常驻** — 后台静默运行，菜单栏随时访问
- **灵活调度** — 日期、时间、重复周期，类似提醒事项的直观设置
- **脚本执行** — 内联脚本或本地文件（.sh、.py、.rb、.js）
- **执行日志** — 捕获 stdout/stderr、退出码、执行耗时
- **系统通知** — 任务成功或失败时推送 macOS 原生通知（支持按任务配置）
- **Crontab 导入** — 一键导入系统 crontab 任务
- **中英双语** — 支持中英文界面，App 内一键切换
- **自动更新** — 检查 GitHub Releases 获取新版本
- **支持 macOS 26** — 液态玻璃视觉特效，旧系统优雅降级

## 系统要求

- macOS 15 (Sequoia) 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

### 下载

从 [Releases](https://github.com/lifedever/TaskTick/releases) 下载最新 `.dmg`：

| 文件 | 架构 |
|------|------|
| `TaskTick-x.x.x-arm64.dmg` | Apple Silicon (M1/M2/M3/M4) |
| `TaskTick-x.x.x-x86_64.dmg` | Intel Mac |

> 首次打开时：**右键点击 TaskTick.app → 打开 → 打开**
>
> 或在终端执行：`xattr -cr /Applications/TaskTick.app`

### 从源码构建

```bash
git clone https://github.com/lifedever/TaskTick.git
cd TaskTick
swift build -c release
swift run
```

## 技术栈

- **SwiftUI** — 声明式 UI 框架
- **SwiftData** — 数据持久化（底层 SQLite）
- **Swift Package Manager** — 构建系统与依赖管理

## 开源协议

GPL-3.0 © [lifedever](https://github.com/lifedever)
