# Changelog

All notable changes to Ensemble will be documented in this file.

## [1.0.0] - 2026-03-03

### Added
- Initial release
- Spawn autonomous Claude Code workers in tmux sessions (`spawn-worker.sh`)
- Live terminal dashboard with Unicode rendering (`dashboard.sh`)
- Cross-worker file-based messaging (`send-message.sh`)
- Background health monitoring with auto-recovery (`monitor.sh`)
- Stream-JSON log parser for phase detection (`parse-phase.sh`)
- macOS and Linux support (cross-platform date/stat)
- Optional Superpowers workflow integration (`--no-superpowers` flag)
- One-line installer (`install.sh`) and uninstaller (`uninstall.sh`)
- Comprehensive test suite (100+ tests)
