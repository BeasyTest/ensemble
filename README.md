<p align="center">
  <img src="assets/logo.svg" alt="Ensemble" width="200">
</p>

<h1 align="center">Ensemble</h1>

<p align="center">
  <em>Orchestrate multiple AI coding agents from your terminal</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://github.com/BeasyTest/ensemble/actions"><img src="https://github.com/BeasyTest/ensemble/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-brightgreen.svg" alt="Platform">
</p>

<!-- Demo GIF will be added in a future release -->
<!-- <p align="center"><img src="assets/demo.gif" alt="Ensemble Demo" width="800"></p> -->

---

## What is Ensemble?

Ensemble lets you run multiple Claude Code instances simultaneously, each working on different parts of your project. Spawn autonomous AI workers in tmux windows, monitor their progress through a live dashboard, and coordinate dependencies between them. It's like having a team of AI developers working in parallel -- turning a multi-hour solo task into a coordinated, concurrent effort.

## Features

- **Spawn autonomous Claude Code workers** in tmux sessions -- each with its own task, budget, and project directory
- **Live terminal dashboard** with progress tracking, workflow phases, and budget consumption
- **Cross-worker communication** for coordinating dependencies (e.g., "the API schema is ready")
- **Automatic health monitoring** and crash recovery with configurable retry logic
- **Works on macOS and Linux** -- compatible with bash 3.2+ out of the box
- **Optional Superpowers workflow integration** for structured brainstorming, TDD, and code review phases

## Quick Start

### Install

```bash
git clone https://github.com/BeasyTest/ensemble.git
cd ensemble
bash install.sh
```

### Use

In Claude Code, type:

```
/orchestrate
```

Then describe what you want to build. Ensemble will break it into workstreams and spawn workers.

### Watch

```bash
tmux attach -t ensemble
```

Use `Ctrl-b` then a window number to switch between workers, or `Ctrl-b n` / `Ctrl-b p` to cycle through them.

## Prerequisites

Before installing, make sure you have the following:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI -- the AI coding assistant (`npm install -g @anthropic-ai/claude-code`)
- [tmux](https://github.com/tmux/tmux) -- terminal multiplexer for managing worker sessions
- [jq](https://jqlang.github.io/jq/) -- lightweight JSON processor for state management
- **bash 3.2+** -- included on macOS and most Linux distributions

The installer will check for these automatically and tell you what's missing.

## How It Works

When you run `/orchestrate`, Ensemble analyzes your goal and breaks it into independent workstreams. Each workstream is assigned to a Claude Code worker instance running in its own tmux window within a shared `ensemble` session. Workers operate autonomously -- following a structured workflow of brainstorming, planning, test-driven development, code review, and completion. The orchestrator monitors worker health, relays messages between workers that depend on each other, and reports progress back to you. All coordination happens through lightweight JSON state files stored in `~/.claude/orchestrator/`.

For a deeper dive into the architecture, see [docs/architecture.md](docs/architecture.md).

## Permissions & Security

Ensemble workers use `--dangerously-skip-permissions` by default to enable fully autonomous operation. This means:

- Workers **can read, write, and execute files** within their project directories without prompting you for confirmation
- Workers run with the same filesystem and network access as your user account
- All worker output is logged to `~/.claude/orchestrator/logs/` for full auditability

**Recommendations:**

- Review the task description carefully before spawning workers -- they will execute exactly what you tell them to
- Use `--safe-mode` for a safer (but slower) operation where workers prompt before destructive actions
- Run Ensemble in an isolated environment (e.g., a VM or container) for untrusted tasks

## Configuration

Ensemble works out of the box with sensible defaults:

| Option | Default | Description |
|--------|---------|-------------|
| Worker budget | `$10 USD` | Maximum spend per worker (`--budget` flag) |
| Budget warning | `80%` | Threshold for budget consumption alerts |
| Health check interval | `60s` | How often the monitor checks worker status |
| Auto-retry | `2 attempts` | How many times to retry a crashed worker |
| Tmux session name | `ensemble` | Name of the shared tmux session |

For detailed configuration options, see [docs/configuration.md](docs/configuration.md).

## Examples

Looking for inspiration? Check out the example workflows:

- [docs/examples/](docs/examples/) -- step-by-step walkthroughs for common use cases

## Troubleshooting

If something goes wrong -- workers stuck, tmux issues, or unexpected errors -- see [docs/troubleshooting.md](docs/troubleshooting.md) for common problems and solutions.

You can also inspect worker state directly:

```bash
# Check all worker statuses
cat ~/.claude/orchestrator/workers/*.json | jq '{name: .name, phase: .phase, progress: .progress}'

# View worker logs
ls ~/.claude/orchestrator/logs/

# Restart the dashboard
bash ~/.claude/skills/ensemble/scripts/dashboard.sh
```

## Contributing

Contributions are welcome! Whether it's a bug fix, new feature, documentation improvement, or example workflow -- we'd love your help.

Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to get started, coding standards, and the pull request process.

## License

MIT -- see [LICENSE](LICENSE) for details.
