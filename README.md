# TaskTick

<p align="center">
  <img src="docs/icon.svg" width="128" height="128" alt="TaskTick Icon">
</p>

<p align="center">
  <strong>A native macOS app for managing scheduled tasks.</strong>
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases">Download</a> ·
  <a href="https://lifedever.github.io/TaskTick/">Website</a> ·
  <a href="https://lifedever.github.io/sponsor/">Sponsor</a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-15-22.51.43@2x.png" width="800" alt="TaskTick Screenshot">
</p>

## Features

- **Menu Bar Resident** — runs in background, always accessible from menu bar
- **Flexible Scheduling** — date, time, repeat cycle with intuitive UI (like Reminders)
- **Script Execution** — inline scripts or local files (.sh, .py, .rb, .js)
- **Execution Logs** — stdout/stderr capture, exit codes, duration tracking
- **Notifications** — macOS system notifications on success/failure (per task)
- **Crontab Import** — import from system crontab with one click
- **i18n** — English & Simplified Chinese, switchable in-app
- **Auto Updates** — checks GitHub Releases for new versions
- **macOS 26 Ready** — liquid glass effects on supported systems

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon or Intel Mac

## Install

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

## Tech Stack

- **SwiftUI** — declarative UI framework
- **SwiftData** — persistence (SQLite under the hood)
- **Swift Package Manager** — build system & dependency management

## License

GPL-3.0 © [lifedever](https://github.com/lifedever)
