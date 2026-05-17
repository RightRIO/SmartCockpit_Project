# VoYah — 智能座舱分布式任务调度监控系统

**面向智能座舱的高可靠事件驱动分布式任务调度系统。**

> 本项目由 **RightRIO** 开发，基于 `epoll` + `timerfd` + `socketpair` 构建，零第三方依赖。

## 文档（多语言）

请在 `docs/` 目录下阅读完整文档：

| 语言 | 文件 |
|------|------|
| 中文 | [docs/README.md](docs/README.md) |
| English | [docs/README_en.md](docs/README_en.md) |
| 日本語 | [docs/README_ja.md](docs/README_ja.md) |
| Русский | [docs/README_ru.md](docs/README_ru.md) |
| العربية | [docs/README_ar.md](docs/README_ar.md) |

## 快速开始

```bash
make                  # 编译
./bin/scheduler 5     # 启动（5 个 Worker，3 ≤ N ≤ 10）
./bin/scheduler --help # 查看帮助
make test             # 运行全部测试
```

## 项目结构

```
VoYah_project/
├── src/scheduler.cpp          # 源代码
├── include/voyah/version.h    # 头文件
├── docs/                      # 完整文档（多语言）
├── test/                      # 9 个测试脚本
├── CMakeLists.txt             # CMake 构建
├── Makefile                   # 快速构建
└── .github/workflows/ci.yml  # CI/CD
```

## 徽章

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue)](docs/CHANGELOG.md)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

---

详细设计文档：[docs/DESIGN.md](docs/DESIGN.md)
