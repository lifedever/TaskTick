---
name: release
description: Build, package, and publish a new TaskTick release to GitHub and Homebrew
user_invocable: true
---

# TaskTick Release Skill

Automate the full release workflow for TaskTick.

## Usage

```
/release <version>
```

Example: `/release 1.0.7`

## Workflow

Follow these steps **in order**:

### 1. Kill running dev instance and build release

```bash
pkill -f "TaskTick Dev" 2>/dev/null
echo "y" | bash scripts/release.sh <version>
```

This builds arm64 + x86_64 DMGs, creates a GitHub tag, and uploads assets to GitHub Releases.

### 2. Get SHA256 of DMGs

```bash
shasum -a 256 .release/TaskTick-<version>-arm64.dmg .release/TaskTick-<version>-x86_64.dmg
```

### 3. Update release notes (bilingual)

Use `gh release edit` to set notes. Always include both English and Chinese sections:

```
## What's Changed

### ...
(English description)

---

## 更新内容

### ...
(Chinese description)

**Full Changelog**: https://github.com/lifedever/TaskTick/compare/v<prev>...v<version>
```

### 4. Update Homebrew Cask

Edit `/Users/gefangshuai/Documents/Dev/myspace/homebrew-tap/Casks/task-tick.rb`:
- Update `version` to new version
- Update `sha256 arm:` and `intel:` with new SHA256 values

Then commit and push:

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/homebrew-tap
git add Casks/task-tick.rb
git commit -m "Update TaskTick cask to v<version>"
git push
```

### 5. Commit and push code changes

Back in the TaskTick repo, stage relevant changed files (do NOT use `git add -A`), commit, and push.

### 6. Report completion

Tell the user:
- Release URL: `https://github.com/lifedever/TaskTick/releases/tag/v<version>`
- Homebrew cask updated
