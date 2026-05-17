# VoYah - 智能座舱分布式任务调度器

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![版本](https://img.shields.io/badge/Version-1.0.0-blue)](CHANGELOG.md)
[![C++ 标准: C++17](https://img.shields.io/badge/C%2B%2B-17-blue)](https://en.cppreference.com/w/cpp/17)
[![平台: Linux](https://img.shields.io/badge/Platform-Linux-green)](https://www.kernel.org/)
[![构建: Make](https://img.shields.io/badge/Build-Make-orange)](Makefile)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

[English](docs/README_en.md) &nbsp;.&nbsp; [中文](docs/README.md) &nbsp;.&nbsp; [日本語](docs/README_ja.md) &nbsp;.&nbsp; [Русский](docs/README_ru.md) &nbsp;.&nbsp; [العربية](docs/README_ar.md)

**面向智能座舱系统的高可靠、事件驱动分布式任务调度器。**
基于 epoll + timerfd + socketpair 构建，零第三方依赖。

</div>

---

## 快速开始

```bash
make                    # 编译
./bin/scheduler 5       # 启动 5 个 Worker
./bin/scheduler --help  # 查看帮助
make test               # 运行全部测试
```

## 特性亮点

- **进程级隔离**：fork() + socketpair，单 Worker 崩溃不影响系统
- **O(1) I/O 多路复用**：epoll LT 模式，高并发下延迟稳定
- **纳秒级定时器**：timerfd + itimerspec，精确控制分发/报表周期
- **动态扩缩容**：运行时 +/- 或 SIGUSR1/SIGUSR2 实时调整 Worker 池
- **故障自愈**：心跳看门狗，崩溃 Worker 自动替换，任务自动抢救
- **优雅退出**：SIGINT + 'X' 协议，无僵尸进程，无任务丢失

## 项目文档

- [中文文档](docs/README.md) — 默认入口
- [English](docs/README_en.md)
- [日本語](docs/README_ja.md)
- [Русский](docs/README_ru.md)
- [العربية](docs/README_ar.md)
- [设计文档](docs/DESIGN.md)

## 许可证

MIT License - 详见 [LICENSE](LICENSE)。
