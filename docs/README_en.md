# VoYah ? Intelligent Cockpit Distributed Task Scheduler

<div align="center">

<!-- Badges -->
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue)](CHANGELOG.md)
[![C++ Standard: C++17](https://img.shields.io/badge/C%2B%2B-17-blue)](https://en.cppreference.com/w/cpp/17)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-green)](https://www.kernel.org/)
[![Build: Make](https://img.shields.io/badge/Build-Make-orange)](Makefile)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

<!-- Language Selector -->
[English](../docs/README_en.md) &nbsp;�&nbsp; [??](../docs/README.md) &nbsp;�&nbsp; [???](../docs/README_ja.md) &nbsp;�&nbsp; [???????](../docs/README_ru.md) &nbsp;�&nbsp; [???????](../docs/README_ar.md)

<!-- Short Description -->
**High-reliability, event-driven distributed task scheduler for intelligent cockpit systems.**  
Built with `epoll` + `timerfd` + `socketpair` ? zero third-party dependencies.

</div>

---

## Table of Contents

- [Highlights](#highlights)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Task Types](#task-types)
- [Interactive Controls](#interactive-controls)
- [Signal-Based Controls](#signal-based-controls)
- [Test Suite](#test-suite)
- [Build & Run](#build--run)
- [Project Structure](#project-structure)
- [Design Decisions](#design-decisions)
- [Performance Characteristics](#performance-characteristics)
- [Roadmap](#roadmap)
- [License](#license)

---

## Highlights

| Feature | Implementation | Benefit |
|---------|---------------|---------|
| **Process Isolation** | `fork()` + `socketpair` | Single Worker crash does not affect the system |
| **O(1) I/O Multiplexing** | `epoll` LT mode | Consistent low latency under high concurrency |
| **Nanosecond-precise Timers** | `timerfd` + `itimerspec` | Deterministic 1s dispatch / 5s reporting cycles |
| **Zero-copy IPC** | `socketpair` SOCK_DGRAM | Efficient Manager ? Worker communication |
| **Graceful Shutdown** | SIGINT capture + `'X'` exit message | No zombie processes, no task loss |
| **Dynamic Scaling** | Runtime `+`/`-` or `SIGUSR1/SIGUSR2` | Adjust Worker pool to cockpit load in real time |
| **Fault Self-healing** | Heartbeat watchdog + `recv` EOF detection | Crashed Workers replaced automatically; pending tasks rescued |
| **Timeout & Retry** | 5s timeout / max 2 retries | No task loss during network jitter |
| **Structured Logging** | JSONL with timestamps | Post-mortem analysis and debugging |

---

## Architecture

```
???????????????????????????????????????????????????????????????????
?                         Manager (Parent)                         ?
?  ?????????????????????????????????????????????????????????????  ?
?  ?                    EventLoop (epoll)                       ?  ?
?  ?   epoll_wait() ???????????????????????????????????????   ?  ?
?  ?   ????????????  ????????????  ????????????  ??????????  ?  ?
?  ?   ?timerfd   ?  ?timerfd   ?  ?timerfd   ?  ? stdin  ?  ?  ?
?  ?   ?1s dispatch?  ?2s heartbeat?  ?5s report ?  ?(+ / -) ?  ?  ?
?  ?   ????????????  ????????????  ????????????  ??????????  ?  ?
?  ?????????????????????????????????????????????????????????????????  ?
????????????????????????????????????????????????????????????????????????
            ?               ?               ?               ?
      ????????????? ????????????? ?????????????
      ? Worker 1  ? ? Worker 2  ? ? Worker N  ?
      ?  (fork)   ? ?  (fork)   ? ?  (fork)   ?
      ? recv_task ? ? recv_task ? ? recv_task ?
      ?  ??sleep ? ?  ??sleep ? ?  ??sleep ?
      ?  ??done  ? ?  ??done  ? ?  ??done  ?
      ????????????? ????????????? ?????????????
```

- **Manager**: single event loop, owns all FD lifecycle, handles dispatch, heartbeat watchdog, and reporting.
- **Worker**: pure execute unit ? `recv ? process ? respond/pong`, no scheduling logic.
- **IPC**: one `socketpair` per Worker, full-duplex, non-blocking on both ends.

---

## Quick Start

```bash
make                    # Build
./bin/scheduler --help  # Show help
./bin/scheduler --version  # Show version
./bin/scheduler 5       # Launch with 5 Workers (3 ? N ? 10)
make clean              # Clean up
```

---

## Task Types

| Type | Processing Time | Cockpit Scenario |
|------|---------------|-----------------|
| **A** | 100 ms | Sensor data ingestion |
| **B** | 200 ms | Media stream processing |
| **C** | 300 ms | Navigation path computation |

---

## Interactive Controls

| Input | Action |
|-------|--------|
| `+` | Add 1 Worker (max 10) |
| `-` | Remove 1 Worker (min 1) |
| `s`/`S` | Print statistics immediately |
| `i`/`I` | Print detailed Worker info |
| `p`/`P` | Print pending task tracker |
| `q`/`Q` | Quit gracefully |
| `Ctrl+C` | Graceful shutdown |

---

## Signal Controls

```bash
kill -SIGUSR1 $(pidof scheduler)   # Add Worker
kill -SIGUSR2 $(pidof scheduler)   # Remove Worker
kill -SIGINT  $(pidof scheduler)   # Graceful shutdown
```

---

## Test Suite

```bash
make test         # Run all 9 test suites
make test-quick   # Smoke tests only
```

| Test | Validates |
|------|-----------|
| `test_boundary.sh` | N=3/10 pass; N=2/11 reject |
| `test_stress.sh` | Workers `kill -9` ? self-healing |
| `test_dynamic.sh` | `+`/`-` live scaling |
| `test_signal.sh` | SIGUSR1/SIGUSR2 controls |
| `test_timeout_retry.sh` | Timeout & retry logic |
| `test_perf.sh` | Throughput, latency metrics |
| `test_concurrent.sh` | Concurrent correctness |
| `test_graceful.sh` | Graceful `'X'` shutdown |
| `test_jsonl.sh` | Structured JSONL logs |

---

## Build & Run

### Requirements

| Dependency | Version |
|------------|---------|
| Linux kernel | 4.x+ |
| GCC or Clang | 7+ (C++17) |
| GNU Make | any recent |

### Commands

```bash
make              # Build ? ./bin/scheduler
make test         # All 9 test suites
make test-quick   # Boundary + graceful tests only
make install      # Install to /usr/local/bin (sudo)
make clean        # Remove ./bin and *.jsonl
make help         # Show targets
```

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `64` | CLI usage error |
| `70` | Runtime error (fork/socketpair/epoll_create) |

---

## Project Structure

```
VoYah_project/
??? CMakeLists.txt              # CMake build (optional)
??? Makefile                    # Quick build entry point
??? .editorconfig               # Editor config
??? .gitignore                  # Git ignore rules
??? LICENSE                     # MIT license
??? AUTHORS                     # Authors list
??? CONTRIBUTING.md             # Contribution guidelines
??? CODE_OF_CONDUCT.md         # Community code of conduct
??? CHANGELOG.md               # Version changelog
??? src/                       # Source code
?   ??? CMakeLists.txt
?   ??? scheduler.cpp             # Complete source (~1000 lines)
??? include/                    # Public headers
?   ??? voyah/
?       ??? version.h          # Version macros
??? docs/                      # Documentation
?   ??? README.md             # Default entry (Chinese)
?   ??? README_en.md          # This file (English)
?   ??? README_ja.md          # Japanese version
?   ??? README_ru.md          # Russian version
?   ??? README_ar.md          # Arabic version
?   ??? DESIGN.md              # System design document
??? test/                      # 9 test scripts
??? examples/                   # Usage examples
?   ??? run_demo.sh           # Demo runner script
??? .github/
    ??? workflows/ci.yml        # GitHub Actions CI/CD
    ??? ISSUE_TEMPLATE/          # Issue templates
    ??? PULL_REQUEST_TEMPLATE.md # PR template
```

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| `epoll` vs `select/poll` | O(1) ready-FD notification, no O(n) full scan |
| Multi-process vs multi-thread | Fault isolation, no lock overhead |
| Native syscalls vs libevent | Zero dependencies, deep Linux I/O understanding |

---

## Performance

| Metric | Value |
|--------|-------|
| Dispatch latency | < 1 ms |
| `epoll_wait` return | < 100 탎 |
| Timer accuracy | nanosecond (`itimerspec`) |
| Worker fork + socketpair | < 5 ms |
| Max Workers | 10 (configurable) |

---

## Roadmap

- [ ] Configurable task weights and per-Worker load limits
- [ ] Priority queue for high-urgency tasks
- [ ] Shared memory (mmap) zero-copy transfer
- [ ] HTTP/MQTT API for remote task injection
- [ ] Multi-Manager HA mode
- [ ] Web dashboard
- [ ] Windows WSL2 compatibility layer

---

## License

MIT License ? see [LICENSE](../LICENSE).
