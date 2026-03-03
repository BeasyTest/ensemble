# Troubleshooting

Common issues and their solutions, organized by symptom.

---

## "tmux session 'ensemble' not found"

**Symptom**: Commands that interact with tmux (resume, deliver messages) fail with a message about the `ensemble` session not existing.

**Cause**: No worker has been spawned yet, or the tmux session was manually killed. The `ensemble` tmux session is created automatically by `spawn-worker.sh` on the first worker spawn.

**Fix**:
- Spawn a worker first: `bash spawn-worker.sh --name test --project ~/myproject --task "test task"`
- Or create the session manually: `tmux new-session -d -s ensemble -n status`

---

## "Worker stuck in initializing"

**Symptom**: A worker's phase remains `initializing` and never progresses, even after several minutes.

**Cause**: The Claude CLI is not installed, not on PATH, or there is an API authentication error. The worker's tmux window may show an error message from the `claude` command.

**Fix**:
1. Check that `claude` is installed: `which claude` or `claude --version`
2. If not installed: `npm install -g @anthropic-ai/claude-code`
3. Check your API key is set (e.g. `ANTHROPIC_API_KEY` environment variable)
4. Attach to the tmux session and inspect the worker window: `tmux attach -t ensemble` then navigate to the worker's window to see any error output
5. Check the worker's log file at `~/.claude/orchestrator/logs/<worker-id>.log`

---

## "Worker status shows 'stuck'"

**Symptom**: The dashboard or monitor reports a worker as `stuck`.

**Cause**: The monitor detected no new log output from the worker for 5+ minutes (300 seconds). This can happen if:
- Claude is processing a very long operation silently
- The worker hit a rate limit or transient API error
- The Claude process crashed without writing a result event

**Fix**:
1. Check the worker's log: `tail -20 ~/.claude/orchestrator/logs/<worker-id>.log`
2. Attach to tmux and inspect the worker window: `tmux attach -t ensemble`
3. If the worker appears dead, the monitor will attempt auto-resume (up to 2 times)
4. To manually resume: the monitor's `resume_worker` function handles this, or you can restart the worker by spawning a new one with the same task

---

## "Budget exceeded"

**Symptom**: Worker stops working and the result event shows the budget was exhausted.

**Cause**: The worker hit the `--max-budget-usd` limit passed to the Claude CLI. The default budget is $10.

**Fix**:
- Spawn a new worker with a higher budget: `bash spawn-worker.sh --name "task-v2" --project ~/project --task "Continue the work" --budget 25`
- For long-running tasks, consider allocating $20-$50 upfront
- Check spent amounts on the dashboard to estimate how much budget a task needs

---

## "Permission denied on scripts"

**Symptom**: Running scripts fails with `Permission denied` errors.

**Cause**: Script files are not marked as executable. This can happen if you copied files manually instead of using `install.sh`.

**Fix**:
```bash
chmod +x ~/.claude/skills/ensemble/scripts/*.sh
```

Or re-run the installer:
```bash
bash install.sh
```

---

## "jq: command not found"

**Symptom**: Any script fails immediately with `jq: command not found`.

**Cause**: The `jq` JSON processor is not installed. All Ensemble scripts require jq for JSON manipulation.

**Fix**:
```bash
# macOS
brew install jq

# Ubuntu / Debian
sudo apt-get install -y jq

# Fedora / RHEL
sudo dnf install -y jq
```

---

## "date: illegal option"

**Symptom**: Scripts fail with date-related errors such as `date: illegal option -- d` on macOS or `date: invalid option -- 'j'` on Linux.

**Cause**: The `date` command has different syntax on macOS (BSD) and Linux (GNU). Ensemble scripts use `$OSTYPE` detection to choose the correct syntax, but edge cases can occur on unusual systems or if scripts are copied between platforms.

**Fix**:
- Reinstall the latest version of Ensemble, which includes cross-platform date handling
- Ensure you are running bash 3.2+ (`bash --version`)
- On macOS, the scripts use `date -j -f` (BSD). On Linux, they use `date -d` (GNU). If you are on an unusual platform, check which `date` variant you have with `date --version` or `man date`

---

## "Dashboard shows no workers"

**Symptom**: Running `dashboard.sh` shows "No worker JSON files found" or an empty display.

**Cause**: No worker JSON files exist in the state directory (`~/.claude/orchestrator/workers/`). Workers have not been spawned yet, or the state directory is pointing to the wrong location.

**Fix**:
1. Spawn at least one worker first: `bash spawn-worker.sh --name test --project ~/myproject --task "test task"`
2. Verify the state directory exists and contains JSON files: `ls ~/.claude/orchestrator/workers/*.json`
3. If using a custom state directory, ensure `ORCH_DIR` is set correctly: `ORCH_DIR=/your/path bash dashboard.sh`

---

## "ERROR: active worker with name 'worker-xxx' already exists"

**Symptom**: Spawning a worker fails because one with the same name is already active.

**Cause**: A worker with the same sanitized name is already running (status is `active`).

**Fix**:
- Choose a different name for the new worker
- If the original worker is done but was not properly marked as completed, manually update its JSON: edit `~/.claude/orchestrator/workers/worker-xxx.json` and set `"status": "completed"`
- Or delete the old worker JSON file if it is no longer needed

---

## "ERROR: required dependency not found: tmux"

**Symptom**: `spawn-worker.sh` fails on startup with a missing dependency error.

**Cause**: One or more required tools (jq, uuidgen, tmux, python3) are not installed.

**Fix**:
```bash
# macOS
brew install tmux jq python3

# Ubuntu / Debian
sudo apt-get install -y tmux jq python3 uuid-runtime
```

The `uuidgen` command is typically pre-installed on macOS. On Linux, it is part of the `uuid-runtime` package.
