# gitlab-jira-flow

Interactive Git, Jira, and GitLab MR workflow assistant for multi-repo AUTOSAR workspaces — automates `.repo` fetching, `develop` syncing, Jira branch/commit formatting, pre-push conflict checks, and one-step GitLab Merge Requests.

## Files

- [`git_flow.bat`](git_flow.bat) — Windows launcher (bypasses PowerShell execution policy and pauses if double-clicked)
- [`git_flow.ps1`](git_flow.ps1) — PowerShell engine (v2.3.0, Windows PowerShell 5.1+ / PS 7+)
- [`git_flow.sh`](git_flow.sh) — Bash engine (v2.3.0, Git Bash / WSL / Linux / macOS)
- [`GIT_FLOW_PLAYBOOK.md`](GIT_FLOW_PLAYBOOK.md) — Complete step-by-step documentation, flags, edge cases, and recovery guide

## Quick Start

Place `git_flow.bat`, `git_flow.ps1`, and `git_flow.sh` in your **Main Project Root** folder and run:

```powershell
# Windows (PowerShell or CMD)
.\git_flow.bat

# Git Bash / Linux
./git_flow.sh
```

See [GIT_FLOW_PLAYBOOK.md](GIT_FLOW_PLAYBOOK.md) for the complete walkthrough and CLI reference.
