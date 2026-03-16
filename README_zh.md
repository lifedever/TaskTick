# TaskTick

<p align="center">
  <img src="docs/icon.svg" width="128" height="128" alt="TaskTick Icon">
</p>

<h3 align="center">TaskTick 定时任务</h3>

<p align="center">
  <strong>macOS 原生定时任务管理应用</strong><br>
  无需 crontab，无需 launchd，交给 TaskTick。
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases/latest"><img src="https://img.shields.io/github/v/release/lifedever/TaskTick?style=flat-square&color=34D399&label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC" alt="最新版本"></a>
  <a href="https://github.com/lifedever/TaskTick/releases"><img src="https://img.shields.io/github/downloads/lifedever/TaskTick/total?style=flat-square&color=7C3AED&label=%E4%B8%8B%E8%BD%BD%E6%AC%A1%E6%95%B0" alt="下载次数"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-blue?style=flat-square" alt="Platform">
  <a href="https://www.gnu.org/licenses/gpl-3.0.html"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases/latest">⬇️ <strong>点击下载最新版本</strong></a> ｜ <a href="https://lifedever.github.io/sponsor/">💖 <strong>捐赠支持</strong></a>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-16-12.47.53@2x.png" width="800" alt="TaskTick 截图">
</p>

## 功能特色

- **菜单栏常驻** — 后台静默运行，菜单栏随时访问
- **灵活调度** — 日期、时间、重复周期，类似提醒事项的直观设置
- **脚本执行** — 内联脚本或本地文件（.sh、.py、.rb、.js）
- **脚本模板** — 内置常用模板（数据库备份、日志清理、健康检查等），支持自定义模板管理
- **执行日志** — 捕获 stdout/stderr、退出码、执行耗时
- **系统通知** — 任务成功或失败时推送 macOS 原生通知（支持按任务配置）
- **Crontab 导入** — 一键导入系统 crontab 任务
- **中英双语** — 支持中英文界面，App 内一键切换
- **自动更新** — 检查 GitHub Releases 获取新版本
- **支持 macOS 26** — 液态玻璃视觉特效，旧系统优雅降级

### 模板管理器

从内置模板快速创建任务，或将常用脚本保存为模板复用。支持分类、备注、脚本校验和文件导入。

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-16-12.12.03@2x.png" width="800" alt="模板管理器">
</p>

## 系统要求

- macOS 15 (Sequoia) 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

### Homebrew（推荐）

```bash
brew tap lifedever/tap
brew install --cask task-tick
```

更新到最新版本：

```bash
brew upgrade --cask task-tick
```

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

## 捐赠支持

如果 TaskTick 对你有帮助，欢迎[捐赠支持](https://lifedever.github.io/sponsor/)开发者持续维护。

## 开源协议

GPL-3.0 © [lifedever](https://github.com/lifedever)
