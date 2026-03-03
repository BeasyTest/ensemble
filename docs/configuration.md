# Configuration

## spawn-worker.sh

Spawns a new Claude Code worker in a tmux window.

```
bash spawn-worker.sh --name <name> --project <dir> --task <task> [options]
```

### Flags

| Flag               | Required | Default | Description                                                  |
|--------------------|----------|---------|--------------------------------------------------------------|
| `--name <name>`    | Yes      | --      | Human-readable name for the worker. Sanitized to lowercase alphanumeric with hyphens, prefixed with `worker-`, truncated to 30 characters after the prefix. |
| `--project <dir>`  | Yes      | --      | Absolute path to the project directory. Must exist on disk.  |
| `--task <task>`    | Yes      | --      | Natural language task description passed to Claude Code.     |
| `--budget <usd>`   | No       | `10`    | Maximum budget in USD for this worker. Passed as `--max-budget-usd` to the Claude CLI. Must be a positive number. |
| `--no-superpowers` | No       | off     | Disables the Superpowers workflow. Uses the generic system prompt template (`worker-system-prompt-generic.md`) instead of the Superpowers template. When this flag is **not** set, workers run with `--dangerously-skip-permissions` enabled, which allows Claude to execute tools without user confirmation. Use `--no-superpowers` for a safer mode where the worker uses a standard prompt without automatic permission grants. |

### Examples

```bash
# Spawn a backend worker with default $10 budget
bash spawn-worker.sh --name "backend" --project ~/projects/api --task "Build a REST API"

# Spawn with higher budget
bash spawn-worker.sh --name "frontend" --project ~/projects/ui --task "Build React app" --budget 25

# Spawn without Superpowers (safer mode)
bash spawn-worker.sh --name "docs" --project ~/projects/docs --task "Write docs" --no-superpowers
```

## monitor.sh

Background health monitor that checks worker state, detects stuck/crashed workers, and auto-resumes.

```
bash monitor.sh [options]
```

### Flags

| Flag              | Required | Default | Description                                                   |
|-------------------|----------|---------|---------------------------------------------------------------|
| `--loop <seconds>`| No       | --      | Run continuously, executing a monitoring cycle every `<seconds>` seconds. Default interval is 10 seconds if no value is provided. Press Ctrl+C to stop. |
| *(no flag)*       | --       | --      | Run a single monitoring cycle and exit (equivalent to `--once`). |

### What a Monitoring Cycle Does

1. Iterates all `*.json` files in the workers directory.
2. For each active worker, calls parse-phase.sh to update phase, cost, progress, and status from the log.
3. Checks if the worker is stuck (no log output for 5+ minutes, configurable threshold of 300 seconds).
4. Marks stuck workers with `status: "stuck"`.
5. Auto-resumes crashed workers if their `resume_count` is less than 2.

### Examples

```bash
# Run one check
bash monitor.sh

# Monitor continuously every 15 seconds
bash monitor.sh --loop 15
```

## dashboard.sh

Live terminal dashboard that renders a table of all worker statuses.

```
bash dashboard.sh            # single render
watch -n 5 bash dashboard.sh # live refresh every 5 seconds
```

### Configuration

The dashboard reads worker JSON files from the state directory and has no command-line flags. It is designed to be run under `watch` for live updates. When spawning workers, `spawn-worker.sh` automatically starts the dashboard in the `status` window of the `ensemble` tmux session using `watch -n 5`.

### Display Columns

| Column    | Description                                    |
|-----------|------------------------------------------------|
| WORKER    | Worker ID (e.g. `worker-backend`)              |
| PROJECT   | Project directory name (last path component)   |
| PHASE     | Current phase (e.g. `implementing`)            |
| PROGRESS  | Visual progress bar (Unicode block characters) |
| PCT       | Numeric progress percentage                    |
| STATUS    | Color-coded status with icon                   |
| HEARTBEAT | Time since last log output                     |

## send-message.sh

Cross-worker messaging via file-based queue.

```
bash send-message.sh <from-worker> <to-worker> <message-text> [payload-json]
```

### Positional Arguments

| Position | Required | Description                                                     |
|----------|----------|-----------------------------------------------------------------|
| 1        | Yes      | Source worker ID (the sender).                                  |
| 2        | Yes      | Destination worker ID (the recipient).                          |
| 3        | Yes      | Human-readable message text.                                    |
| 4        | No       | Optional JSON payload (defaults to `{}`). Must be valid JSON.   |

### Examples

```bash
# Simple text message
bash send-message.sh worker-backend worker-frontend "API schema is ready"

# Message with JSON payload
bash send-message.sh worker-backend worker-frontend "API schema ready" \
  '{"endpoints":["/api/todos","/api/users"],"port":5000}'
```

## parse-phase.sh

Stream-JSON log parser for phase detection. Typically called by monitor.sh rather than directly.

```
bash parse-phase.sh <log-file>       # output JSON summary
source parse-phase.sh --dry-run      # load functions only (for use by other scripts)
```

### Output

When run directly, outputs a JSON object:

```json
{
  "phase": "implementing",
  "cost": 2.45,
  "status": "running",
  "progress": 60
}
```

### Available Functions (when sourced)

| Function             | Arguments       | Returns                                |
|----------------------|-----------------|----------------------------------------|
| `detect_phase`       | `log_file`      | Phase name string                      |
| `extract_cost`       | `log_file`      | Cost as decimal number                 |
| `detect_completion`  | `log_file`      | `running`, `success`, or `error_*`     |
| `extract_turns`      | `log_file`      | Number of conversation turns           |
| `extract_last_text`  | `log_file [n]`  | Last N assistant text blocks           |
| `estimate_progress`  | `phase`         | Progress percentage (0-100)            |

## Environment Variables

| Variable            | Default                       | Description                                          |
|---------------------|-------------------------------|------------------------------------------------------|
| `ENSEMBLE_STATE_DIR`| `~/.claude/orchestrator`      | Override the root state directory for workers, logs, and messages. Not yet implemented in all scripts (planned). |
| `ORCH_DIR`          | `~/.claude/orchestrator`      | Legacy alias for the state directory. Used by monitor.sh, send-message.sh, and dashboard.sh. Set this to redirect state storage during testing or for custom installations. |

### Example: Custom State Directory

```bash
# Run monitor against a custom state directory
ORCH_DIR=/tmp/test-orchestrator bash monitor.sh --loop 10

# Run dashboard against the same custom directory
ORCH_DIR=/tmp/test-orchestrator bash dashboard.sh
```
