#!/bin/bash
set -euo pipefail

echo "=== Ensemble Installation Verification ==="
ERRORS=0

# Check scripts
for script in spawn-worker.sh parse-phase.sh monitor.sh dashboard.sh send-message.sh; do
    if [ -x "$HOME/.claude/skills/ensemble/scripts/$script" ]; then
        echo "  OK: $script (executable)"
    else
        echo "  MISSING/NOT-EXECUTABLE: $script"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check templates
for tmpl in orchestrator.md worker-system-prompt.md; do
    if [ -f "$HOME/.claude/skills/ensemble/templates/$tmpl" ]; then
        echo "  OK: templates/$tmpl"
    else
        echo "  MISSING: templates/$tmpl"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check SKILL.md
if [ -f "$HOME/.claude/skills/ensemble/SKILL.md" ]; then
    if head -1 "$HOME/.claude/skills/ensemble/SKILL.md" | grep -q "^---"; then
        echo "  OK: SKILL.md (valid frontmatter)"
    else
        echo "  WARN: SKILL.md missing frontmatter"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "  MISSING: SKILL.md"
    ERRORS=$((ERRORS + 1))
fi

# Check slash command
if [ -f "$HOME/.claude/commands/orchestrate.md" ]; then
    echo "  OK: /orchestrate command"
else
    echo "  MISSING: /orchestrate command"
    ERRORS=$((ERRORS + 1))
fi

# Check runtime directories
for dir in workers messages logs; do
    if [ -d "$HOME/.claude/orchestrator/$dir" ]; then
        echo "  OK: orchestrator/$dir/"
    else
        echo "  MISSING: orchestrator/$dir/"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "Installation complete. All checks passed."
    echo ""
    echo "Usage:"
    echo "  In Claude Code, type: /orchestrate"
    echo "  Or invoke the skill: ensemble"
    echo ""
    echo "  To view workers: tmux attach -t ensemble"
else
    echo "Installation incomplete: $ERRORS errors found."
    exit 1
fi
