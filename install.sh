#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
REPO_URL="https://github.com/OWNER/ensemble.git"

# ── Header ────────────────────────────────────────────────────────
echo "=== Ensemble v${VERSION} Installer ==="
echo ""

# ── 1. Check dependencies ────────────────────────────────────────
missing=()
for cmd in tmux jq claude; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required dependencies: ${missing[*]}"
    echo ""

    # Detect platform
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "Install on macOS with Homebrew:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                claude) echo "  npm install -g @anthropic-ai/claude-code" ;;
                *)      echo "  brew install $cmd" ;;
            esac
        done
    else
        echo "Install on Linux:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                claude) echo "  npm install -g @anthropic-ai/claude-code" ;;
                *)      echo "  sudo apt-get install -y $cmd" ;;
            esac
        done
    fi
    exit 1
fi

echo "All dependencies found."

# ── 2. Determine source directory ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/src/spawn-worker.sh" ]]; then
    echo "Installing from local repository: ${SCRIPT_DIR}"
    SOURCE_DIR="${SCRIPT_DIR}"
else
    echo "Cloning repository from GitHub..."
    CLONE_DIR="$(mktemp -d)"
    trap 'rm -rf "${CLONE_DIR}"' EXIT
    git clone --depth 1 "${REPO_URL}" "${CLONE_DIR}"
    SOURCE_DIR="${CLONE_DIR}"
fi

# ── 3. Create directories ────────────────────────────────────────
echo "Creating directories..."
mkdir -p ~/.claude/skills/ensemble/scripts
mkdir -p ~/.claude/skills/ensemble/templates
mkdir -p ~/.claude/orchestrator/workers
mkdir -p ~/.claude/orchestrator/messages
mkdir -p ~/.claude/orchestrator/logs
mkdir -p ~/.claude/commands

# ── 4. Copy files ────────────────────────────────────────────────
echo "Copying files..."

# Scripts
cp "${SOURCE_DIR}/src/"*.sh ~/.claude/skills/ensemble/scripts/

# Templates
cp "${SOURCE_DIR}/templates/"*.md ~/.claude/skills/ensemble/templates/

# Skill definition
cp "${SOURCE_DIR}/skill/SKILL.md" ~/.claude/skills/ensemble/SKILL.md

# ── 5. Make scripts executable ───────────────────────────────────
chmod +x ~/.claude/skills/ensemble/scripts/*.sh

# ── 6. Create /orchestrate command (only if not exists) ──────────
COMMAND_FILE=~/.claude/commands/orchestrate.md
if [[ ! -f "${COMMAND_FILE}" ]]; then
    echo "Creating /orchestrate command..."
    cat > "${COMMAND_FILE}" <<'COMMAND'
---
disable-model-invocation: true
---

Use the `ensemble` skill to manage this task. Invoke skill: `ensemble`
COMMAND
else
    echo "/orchestrate command already exists, skipping."
fi

# ── 7. Success ───────────────────────────────────────────────────
echo ""
echo "=== Ensemble v${VERSION} installed successfully! ==="
echo ""
echo "Usage:"
echo "  In any Claude Code session, type:  /orchestrate"
echo "  Or ask Claude to use the ensemble skill directly."
echo ""
echo "Installed to: ~/.claude/skills/ensemble/"
echo "Command:      ~/.claude/commands/orchestrate.md"
echo ""
echo "To uninstall, run:  bash ${SCRIPT_DIR}/uninstall.sh"
