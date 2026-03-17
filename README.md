# TaskTick

<p align="center">
  <img src="docs/icon.svg" width="128" height="128" alt="TaskTick Icon">
</p>

<h3 align="center">TaskTick</h3>

<p align="center">
  <strong>A native macOS app for managing scheduled tasks.</strong><br>
  No crontab, no launchd — just TaskTick.
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases/latest"><img src="https://img.shields.io/github/v/release/lifedever/TaskTick?style=flat-square&color=34D399&label=Latest" alt="Latest Release"></a>
  <a href="https://github.com/lifedever/TaskTick/releases"><img src="https://img.shields.io/github/downloads/lifedever/TaskTick/total?style=flat-square&color=7C3AED&label=Downloads" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <a href="https://www.gnu.org/licenses/gpl-3.0.html"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases/latest">⬇️ <strong>Download Latest</strong></a> ｜ <a href="https://www.lifedever.com/sponsor/">💖 <strong>Sponsor</strong></a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-16-12.47.53@2x.png" width="800" alt="TaskTick Screenshot">
</p>

## Features

- **Menu Bar Resident** — runs in background, always accessible from menu bar
- **Flexible Scheduling** — date, time, repeat cycle with intuitive UI (like Reminders)
- **Script Execution** — inline scripts or local files (.sh, .py, .rb, .js)
- **Script Templates** — built-in templates (DB backup, log cleanup, health check, etc.) + create and manage your own
- **Execution Logs** — stdout/stderr capture, exit codes, duration tracking
- **Notifications** — macOS system notifications on success/failure (per task)
- **Crontab Import** — import from system crontab with one click
- **i18n** — English & Simplified Chinese, switchable in-app
- **Auto Updates** — checks GitHub Releases for new versions
- **macOS 26 Ready** — liquid glass effects on supported systems

### Template Manager

Quickly create tasks from built-in templates or save your own scripts for reuse. Supports categories, notes, script validation, and file import.

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-16-12.12.03@2x.png" width="800" alt="Template Manager">
</p>

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac

## Install

### Homebrew (Recommended)

```bash
brew tap lifedever/tap
brew install --cask task-tick
```

Update to the latest version:

```bash
brew upgrade --cask task-tick
```

### Download

Grab the latest `.dmg` from [Releases](https://github.com/lifedever/TaskTick/releases):

| File | Architecture |
|------|-------------|
| `TaskTick-x.x.x-arm64.dmg` | Apple Silicon (M1/M2/M3/M4) |
| `TaskTick-x.x.x-x86_64.dmg` | Intel Mac |

> On first launch: **Right-click TaskTick.app → Open → Open**
>
> Or run: `xattr -cr /Applications/TaskTick.app`

### Build from Source

```bash
git clone https://github.com/lifedever/TaskTick.git
cd TaskTick
swift build -c release
swift run
```

## Sponsor

If TaskTick is useful to you, consider [sponsoring](https://www.lifedever.com/sponsor/) the developer to support ongoing maintenance.

## License

GPL-3.0 © [lifedever](https://github.com/lifedever)
