# Contributing to Ensemble

## Getting Started

1. Fork the repo
2. Clone your fork
3. Run the tests: `bash tests/test-spawn.sh && bash tests/test-parse-phase.sh && bash tests/test-monitor.sh && bash tests/test-send-message.sh`

## Development

- All scripts are bash (3.2+ compatible for macOS)
- Use `set -euo pipefail` in all scripts
- Test with both macOS and Linux if possible
- Follow existing code patterns

## Running Tests

```bash
# Run all unit tests
bash tests/test-spawn.sh
bash tests/test-parse-phase.sh
bash tests/test-monitor.sh
bash tests/test-send-message.sh

# Run integration tests (requires tmux)
bash tests/test-integration.sh

# Verify installation
bash install.sh && bash tests/verify-install.sh
```

## Pull Requests

- Create a branch for your feature/fix
- Add tests for new functionality
- Ensure all tests pass on both macOS and Linux
- Keep PRs focused and small
- Describe what and why in the PR description

## Reporting Issues

Use GitHub Issues. Include:
- Your OS and version
- bash version (`bash --version`)
- Claude Code version (`claude --version`)
- Steps to reproduce
- Expected vs actual behavior

## Code Style

- Use shellcheck-clean bash
- Quote all variable expansions
- Use `local` for function variables
- Prefer `[[ ]]` over `[ ]` for conditionals in new code
- Use meaningful variable names
