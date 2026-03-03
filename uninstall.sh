#!/usr/bin/env bash
set -euo pipefail

echo "=== Ensemble Uninstaller ==="
echo ""

# ── 1. Remove skill files ────────────────────────────────────────
if [[ -d ~/.claude/skills/ensemble ]]; then
    echo "Removing ~/.claude/skills/ensemble/ ..."
    rm -rf ~/.claude/skills/ensemble
else
    echo "Skill directory not found — already removed."
fi

# ── 2. Remove /orchestrate command ───────────────────────────────
if [[ -f ~/.claude/commands/orchestrate.md ]]; then
    echo "Removing ~/.claude/commands/orchestrate.md ..."
    rm -f ~/.claude/commands/orchestrate.md
else
    echo "Command file not found — already removed."
fi

# ── 3. Optionally remove orchestrator state data ─────────────────
if [[ -d ~/.claude/orchestrator ]]; then
    echo ""
    echo "Orchestrator state data exists at ~/.claude/orchestrator/"
    echo "This includes worker state, messages, and logs."
    read -p "Delete orchestrator state data? [y/N] " -r answer
    answer="${answer:-N}"
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        echo "Removing ~/.claude/orchestrator/ ..."
        rm -rf ~/.claude/orchestrator
    else
        echo "Keeping orchestrator state data."
    fi
fi

# ── 4. Success ───────────────────────────────────────────────────
echo ""
echo "=== Ensemble uninstalled successfully. ==="
