# VoYah - Intelligent Cockpit Distributed Task Scheduler

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue)](CHANGELOG.md)
[![C++: C++17](https://img.shields.io/badge/C%2B%2B-17-blue)](https://en.cppreference.com/w/cpp/17)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-green)](https://www.kernel.org/)
[![Build: Make](https://img.shields.io/badge/Build-Make-orange)](Makefile)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

[English](README_en.md) &nbsp;.&nbsp; [Chinese](README.md) &nbsp;.&nbsp; [Japanese](README_ja.md) &nbsp;.&nbsp; [Russian](README_ru.md) &nbsp;.&nbsp; [Arabic](README_ar.md)

**High-reliability event-driven distributed task scheduler for intelligent cockpit systems.**
Built with epoll + timerfd + socketpair - zero third-party dependencies.

</div>

---

## Table of Contents

- [Highlights](#highlights)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Task Types](#task-types)
- [Interactive Controls](#interactive-controls)
- [Signal Controls](#signal-controls)
- [Test Suite](#test-suite)
- [Build and Run](#build-and-run)
- [Project Structure](#project-structure)
- [Design Decisions](#design-decisions)
- [Performance](#performance)
- [Roadmap](#roadmap)
- [License](#license)

---

## Highlights

| Feature | Implementation | Benefit |
|---------|---------------|---------|
| **Process Isolation** | fork() + socketpair | Single Worker crash does not affect system |
| **O(1) I/O Multiplexing** | epoll LT mode | Consistent low latency under high concurrency |
| **Nanosecond Timers** | timerfd + itimerspec | Deterministic dispatch/reporting cycles |
| **Zero-copy IPC** | socketpair SOCK_DGRAM | Efficient Manager-Worker communication |
| **Graceful Shutdown** | SIGINT + 'X' message | No zombies, no task loss |
| **Dynamic Scaling** | Runtime +/- or SIGUSR1/SIGUSR2 | Adjust pool size in real time |
| **Fault Self-healing** | Heartbeat watchdog | Crashed Workers replaced; pending tasks rescued |
| **Timeout and Retry** | 5s timeout / max 2 retries | No task loss during network jitter |
| **Structured Logging** | JSONL with timestamps | Post-mortem analysis |

---

## Architecture

```
+-----------------------------------------------------------------------+
|                       Manager (parent process)                          |
|  +---------------------------------------------------------------+    |
|  |                     EventLoop (epoll)                           |    |
|  |   epoll_wait() ------------------------------------------->  |    |
|  |   +-----------+ +-----------+ +-----------+ +--------+        |    |
|  |   |timerfd    | |timerfd    | |timerfd    | | stdin  |        |    |
|  |   |1s dispatch| |2s heartbeat| |5s report  | |(+ / -) |        |    |
|  |   +-----+-----+ +-----+-----+ +-----+-----+ +---+----+        |    |
|  +--------+-----------+-----------+-----------+------+----+--------+    |
+----------+-----------+-----------+-----------+------+----+---------------+
            |           |           |           |      |
            V           V           V           V      V
      +---------+ +---------+ +---------+
      | Worker 1| | Worker 2| | Worker N |
      | (fork) | | (fork) | | (fork) |
      |recv_task| |recv_task| |recv_task|
      | +-sleep| | +-sleep| | +-sleep|
      | +-done | | +-done | | +-done |
      | +-pong | | +-pong | | +-pong |
      +---------+ +---------+ +---------+
```

- **Manager**: single event loop, owns all FD lifecycle, handles dispatch, heartbeat watchdog, reporting.
- **Worker**: pure execute unit - receive, process, respond/pong. No scheduling logic.
- **IPC**: one socketpair per Worker, full-duplex, non-blocking on both ends.

---

## Quick Start

```bash
make                    # Build
./bin/scheduler --help  # Show help
./bin/scheduler 5       # Launch with 5 Workers (3 <= N <= 10)
make test               # Run all tests
make clean              # Clean up
```

---

## Task Types

| Type | Processing Time | Cockpit Scenario |
|------|-----------------|-----------------|
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
make test       # Run all 9 test suites
make test-quick # Smoke tests only
```

| Test | Validates |
|------|-----------|
| `test_boundary.sh` | N=3/10 pass; N=2/11 reject |
| `test_stress.sh` | Workers kill -9 -> self-healing |
| `test_dynamic.sh` | +/- live scaling |
| `test_signal.sh` | SIGUSR1/SIGUSR2 controls |
| `test_timeout_retry.sh` | Timeout and retry logic |
| `test_perf.sh` | Throughput and latency metrics |
| `test_concurrent.sh` | Concurrent correctness |
| `test_graceful.sh` | Graceful shutdown with X protocol |
| `test_jsonl.sh` | Structured JSONL logs |

---

## Build and Run

### Requirements

| Dependency | Version |
|------------|---------|
| Linux kernel | 4.x+ |
| GCC or Clang | 7+ (C++17) |
| GNU Make | any recent |

### Commands

```bash
make              # Build -> ./bin/scheduler
make test         # All 9 test suites
make test-quick   # Boundary + graceful tests only
make install      # Install to /usr/local/bin
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
|-- CMakeLists.txt              # CMake build (optional)
|-- Makefile                    # Quick build entry point
|-- .editorconfig               # Editor config
|-- .gitignore                  # Git ignore rules
|-- LICENSE                     # MIT license
|-- AUTHORS                     # Authors list
|-- CONTRIBUTING.md             # Contribution guidelines
|-- CODE_OF_CONDUCT.md         # Community code of conduct
|-- CHANGELOG.md               # Version changelog
|-- src/                       # Source code
|   |-- CMakeLists.txt
|   +-- scheduler.cpp           # Complete source (~1000 lines)
|-- include/                    # Public headers
|   +-- voyah/
|       +-- version.h          # Version macros
|-- docs/                      # Documentation
|   |-- README.md             # Default entry (Chinese)
|   |-- README_en.md          # English version
|   |-- README_ja.md          # Japanese version
|   |-- README_ru.md          # Russian version
|   |-- README_ar.md          # This file (Arabic)
|   +-- DESIGN.md              # System design document
|-- test/                      # 9 test scripts
|-- examples/                   # Usage examples
|   +-- run_demo.sh           # Demo runner script
+-- .github/
    |-- workflows/ci.yml        # GitHub Actions CI/CD
    |-- ISSUE_TEMPLATE/          # Issue templates
    +-- PULL_REQUEST_TEMPLATE.md # PR template
```

---

## Design Decisions

### Why epoll over select / poll?

| Criterion | select | poll | epoll |
|-----------|--------|------|-------|
| FD limit | FD_SETSIZE (1024) | Unlimited | Unlimited |
| Time complexity | O(n) scan all | O(n) scan all | **O(1) ready-FDs only** |
| Per-call memory | High (in/out copies) | High (in/out copies) | Low (registered once) |
| Cockpit fit | No | No | **Yes - real-time, microsecond latency** |

### Why multi-process over multi-thread?

- **Reliability**: one Worker crash is isolated, Manager continues running.
- **No locks**: process boundary eliminates data races, no mutex overhead.
- **Modern fork**: copy-on-write makes fork near-zero cost for read-mostly workloads.

### Why native syscalls over libevent / libuv?

- Demonstrates deep understanding of Linux I/O fundamentals.
- Zero third-party dependencies - pure GNU/Linux.
- epoll + timerfd + socketpair fully covers all I/O multiplexing, timing, and IPC needs.

---

## Performance

| Metric | Value |
|--------|-------|
| Dispatch latency (1 Worker, 1 task) | < 1 ms |
| epoll_wait return time | < 100 us |
| Timer accuracy (timerfd) | nanosecond (itimerspec) |
| Worker fork + socketpair setup | < 5 ms |
| Graceful shutdown (N Workers) | < 100 ms + N x Worker processing time |
| Max concurrent Workers | 10 (configurable) |

---

## Roadmap

- [ ] Configurable task weights and per-Worker load limits
- [ ] Priority queue for high-urgency cockpit tasks
- [ ] Shared memory (mmap) zero-copy transfer
- [ ] HTTP/MQTT API for remote task injection
- [ ] Multi-Manager HA mode with leader election
- [ ] Web dashboard for real-time visualization
- [ ] Windows WSL2 compatibility layer

---

## License

MIT License - see [LICENSE](../LICENSE).
