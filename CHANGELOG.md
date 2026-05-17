# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Multi-language README support (English, Chinese, Japanese, Russian, Arabic)
- CI/CD pipeline (GitHub Actions)
- Issue and PR templates
- `.editorconfig` for consistent editor settings

### Changed
- README: redesigned with badges, TOC, highlights table, architecture diagram
- Makefile: added `help`, `test-quick`, and `distclean` targets
- `.gitignore`: extended coverage for build artifacts and IDE files

### Fixed
- README: corrected project structure and command examples
- All README language variants: synchronized content and links

---

## [1.0.0] â€?2026-05-15

### Added
- Manager-Worker multi-process architecture
- `epoll` LT-mode event loop
- `timerfd` for precise 1s dispatch / 5s reporting cycles
- `socketpair` SOCK_DGRAM full-duplex IPC
- Dynamic Worker pool scaling via terminal (`+`/`-`) and signals (`SIGUSR1/SIGUSR2`)
- Graceful shutdown protocol (SIGINT â†?`'X'` message â†?`waitpid`å›žæ”¶)
- Task retry mechanism with configurable max retries
- Heartbeat watchdog (2s ping / 6s timeout per Worker)
- JSONL structured logging with per-run timestamped files
- Comprehensive test suite (9 test scripts)
- `DESIGN.md` with full architecture and design rationale

### Features

| Feature | Description |
|---------|-------------|
| Process isolation | `fork()` Worker processes, crash containment |
| O(1) I/O multiplexing | `epoll` ready-FD notification |
| Zero-copy IPC | `socketpair` SOCK_DGRAM, no memcpy overhead |
| Fault self-healing | `recv` EOF detection, automatic Worker removal |
| Task types | A (100ms), B (200ms), C (300ms) simulation |
| CLI validation | N must be 3â€?0, rejects invalid inputs |

---

_[Unreleased]: https://github.com/rightrio/voyah-scheduler/compare/v1.0.0...HEAD
_[1.0.0]: https://github.com/rightrio/voyah-scheduler/releases/tag/v1.0.0
