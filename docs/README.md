# VoYah - 智能座舱分布式任务调度器

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![版本](https://img.shields.io/badge/Version-1.0.0-blue)](CHANGELOG.md)
[![C++ 标准: C++17](https://img.shields.io/badge/C%2B%2B-17-blue)](https://en.cppreference.com/w/cpp/17)
[![平台: Linux](https://img.shields.io/badge/Platform-Linux-green)](https://www.kernel.org/)
[![构建: Make](https://img.shields.io/badge/Build-Make-orange)](Makefile)
[![CI](https://img.shields.io/github/actions/workflow/status/rightrio/voyah-scheduler/ci.yml?branch=main)](https://github.com/rightrio/voyah-scheduler/actions)

[English](README_en.md) &nbsp;.&nbsp; [中文](README.md) &nbsp;.&nbsp; [日本語](README_ja.md) &nbsp;.&nbsp; [Русский](README_ru.md) &nbsp;.&nbsp; [العربية](README_ar.md)

**面向智能座舱系统的高可靠、事件驱动的分布式任务调度器。**
基于 epoll + timerfd + socketpair 构建，零第三方依赖。

</div>

---

## 目录

- [特性亮点](#特性亮点)
- [系统架构](#系统架构)
- [快速上手](#快速上手)
- [任务类型](#任务类型)
- [交互控制](#交互控制)
- [信号控制](#信号控制)
- [测试套件](#测试套件)
- [构建与运行](#构建与运行)
- [项目结构](#项目结构)
- [设计决策](#设计决策)
- [性能指标](#性能指标)
- [Roadmap](#roadmap)
- [许可证](#许可证)

---

## 特性亮点

| 特性 | 实现方式 | 收益 |
|------|----------|------|
| **进程级隔离** | fork() + socketpair | 单个 Worker 崩溃不影响系统整体 |
| **O(1) I/O 多路复用** | epoll LT 模式 | 高并发下延迟稳定可控 |
| **纳秒级精定时器** | timerfd + itimerspec | 1s 分发 / 5s 报表周期精确可靠 |
| **零拷贝 IPC** | socketpair SOCK_DGRAM | Manager 与 Worker 间高效通信 |
| **优雅退出** | SIGINT 捕获 + 'X' 退出消息 | 无僵尸进程，无任务丢失 |
| **运行时动态扩缩容** | `+`/`-` 或 SIGUSR1/SIGUSR2 | 实时调整 Worker 池大小 |
| **故障自愈** | 心跳看门狗 + recv EOF 检测 | 崩溃 Worker 自动替换，待处理任务自动抢救 |
| **超时重试** | 5s 超时 / 最多 2 次重试 | 网络抖动期间任务不丢失 |
| **结构化日志** | JSONL 带时间戳 | 支持事后分析和问题定位 |

---

## 系统架构

```
+-----------------------------------------------------------------------+
|                          Manager（父进程）                                |
|  +---------------------------------------------------------------+    |
|  |                     EventLoop（epoll）                           |    |
|  |   epoll_wait() ------------------------------------------->  |    |
|  |   +-----------+ +-----------+ +-----------+ +--------+        |    |
|  |   |timerfd    | |timerfd    | |timerfd    | | stdin  |        |    |
|  |   |1s 分发任务| |2s 心跳保活| |5s 打印报表| |(+ / -)|        |    |
|  |   +-----+-----+ +-----+-----+ +-----+-----+ +---+----+        |    |
|  +--------+-----------+-----------+-----------+------+----+--------+    |
+----------+-----------+-----------+-----------+------+----+---------------+
            |           |           |           |      |
            V           V           V           V      V
      +---------+ +---------+ +---------+
      | Worker 1| | Worker 2| | Worker N |
      | (fork)  | | (fork)  | | (fork)  |
      |recv_task| |recv_task| |recv_task|
      | +-sleep | | +-sleep | | +-sleep |
      | +-done  | | +-done  | | +-done  |
      | +-pong  | | +-pong  | | +-pong  |
      +---------+ +---------+ +---------+
```

- **Manager**：单一事件循环，拥有所有 FD 的生命周期，负责任务分发、心跳看门狗和报表统计。
- **Worker**：纯执行单元——接收、处理、响应 pong。无任何调度逻辑。
- **IPC**：每个 Worker 独占一条 socketpair，全双工，两端均设为非阻塞。

---

## 快速上手

```bash
make                    # 编译
./bin/scheduler --help  # 查看帮助
./bin/scheduler 5       # 启动 5 个 Worker（3 <= N <= 10）
make test               # 运行全部测试
make clean              # 清理产物
```

---

## 任务类型

| 类型 | 处理耗时 | 座舱场景 |
|------|---------|---------|
| **A** | 100 ms | 传感器数据摄取 |
| **B** | 200 ms | 媒体流处理 |
| **C** | 300 ms | 导航路径计算 |

---

## 交互控制

| 输入 | 操作 |
|------|------|
| `+` | 增加 1 个 Worker（上限 10） |
| `-` | 减少 1 个 Worker（至少保留 1 个） |
| `s`/`S` | 立即打印统计信息 |
| `i`/`I` | 打印详细 Worker 状态 |
| `p`/`P` | 打印待处理任务跟踪器 |
| `q`/`Q` | 优雅退出 |
| `Ctrl+C` | 优雅关闭 |

---

## 信号控制

```bash
kill -SIGUSR1 $(pidof scheduler)   # 增加 Worker
kill -SIGUSR2 $(pidof scheduler)   # 减少 Worker
kill -SIGINT  $(pidof scheduler)   # 优雅退出
```

---

## 测试套件

```bash
make test       # 运行全部 9 个测试用例
make test-quick # 仅运行冒烟测试
```

| 测试用例 | 验证内容 |
|---------|---------|
| `test_boundary.sh` | N=3/10 通过；N=2/11 拒绝 |
| `test_stress.sh` | Worker 被 kill -9 后系统自愈 |
| `test_dynamic.sh` | `+`/`-` 动态扩缩容 |
| `test_signal.sh` | SIGUSR1/SIGUSR2 信号控制 |
| `test_timeout_retry.sh` | 超时与重试逻辑 |
| `test_perf.sh` | 吞吐量与延迟指标 |
| `test_concurrent.sh` | 并发正确性 |
| `test_graceful.sh` | 带 X 协议的优雅退出 |
| `test_jsonl.sh` | 结构化 JSONL 日志 |

---

## 构建与运行

### 环境依赖

| 依赖项 | 版本要求 |
|--------|---------|
| Linux 内核 | 4.x+ |
| GCC 或 Clang | 7+（C++17） |
| GNU Make | 任意近期版本 |

### 构建命令

```bash
make              # 编译 -> ./bin/scheduler
make test         # 运行全部 9 个测试
make test-quick   # 仅边界测试 + 优雅退出测试
make install      # 安装到 /usr/local/bin（需要 sudo）
make clean        # 清理 ./bin 和 *.jsonl
make help         # 查看所有构建目标
```

### 退出码

| 退出码 | 含义 |
|--------|------|
| `0` | 成功 |
| `64` | 命令行参数错误 |
| `70` | 运行时错误（fork/socketpair/epoll_create 失败） |

---

## 项目结构

```
VoYah_project/
|-- CMakeLists.txt              # CMake 构建（可选）
|-- Makefile                    # 快速构建入口
|-- .editorconfig              # 编辑器配置
|-- .gitignore                 # Git 忽略规则
|-- LICENSE                    # MIT 许可证
|-- AUTHORS                    # 作者列表
|-- CONTRIBUTING.md            # 贡献指南
|-- CODE_OF_CONDUCT.md         # 社区行为规范
|-- CHANGELOG.md              # 版本变更日志
|-- src/                       # 源代码
|   |-- CMakeLists.txt
|   +-- scheduler.cpp           # 完整实现（约 1000 行）
|-- include/                   # 公开头文件
|   +-- voyah/
|       +-- version.h          # 版本宏定义
|-- docs/                      # 项目文档
|   |-- README.md             # 默认入口（中文）
|   |-- README_en.md          # 英文版
|   |-- README_ja.md          # 日文版
|   |-- README_ru.md          # 俄文版
|   |-- README_ar.md          # 阿拉伯文版
|   +-- DESIGN.md              # 系统设计文档
|-- test/                      # 9 个测试脚本
|-- examples/                   # 使用示例
|   +-- run_demo.sh           # 演示运行脚本
+-- .github/
    |-- workflows/ci.yml        # GitHub Actions CI/CD
    |-- ISSUE_TEMPLATE/          # Issue 模板
    +-- PULL_REQUEST_TEMPLATE.md # PR 模板
```

---

## 设计决策

### 为什么选 epoll 而不是 select / poll？

| 指标 | select | poll | epoll |
|------|--------|------|-------|
| FD 数量限制 | FD_SETSIZE（1024） | 无限制 | 无限制 |
| 时间复杂度 | O(n) 扫描全部 | O(n) 扫描全部 | **O(1) 仅返回就绪 FD** |
| 每次调用内存 | 高（in/out 两次拷贝） | 高（in/out 两次拷贝） | 低（一次性注册） |
| 座舱场景适配 | 否 | 否 | **是——实时、微秒级延迟** |

### 为什么选多进程而不是多线程？

- **可靠性**：单个 Worker 崩溃不影响 Manager，系统持续运行。
- **无锁**：进程边界天然消除数据竞争，无需互斥锁。
- **现代 fork**：写时复制使 fork 对只读为主的工作负载几乎没有开销。

### 为什么用原生系统调用而不是 libevent / libuv？

- 展示对 Linux I/O 底层原理的深刻理解。
- 零第三方依赖——纯 GNU/Linux。
- epoll + timerfd + socketpair 完整覆盖所有 I/O 多路复用、计时和 IPC 需求。

---

## 性能指标

| 指标 | 数值 |
|------|------|
| 分发延迟（1 Worker，1 任务） | < 1 ms |
| epoll_wait 返回时间 | < 100 us |
| 定时器精度（timerfd） | 纳秒级（itimerspec） |
| Worker fork + socketpair 建立耗时 | < 5 ms |
| 优雅退出耗时（N 个 Worker） | < 100 ms + N x Worker 处理时间 |
| 最大并发 Worker 数 | 10（可配置） |

---

## Roadmap

- [ ] 支持任务权重和 Worker 负载上限配置
- [ ] 高优先级座舱任务的优先队列
- [ ] 共享内存（mmap）零拷贝传输
- [ ] HTTP/MQTT API 远程注入任务
- [ ] 多 Manager 高可用模式与主备选举
- [ ] Web 实时可视化仪表盘
- [ ] Windows WSL2 兼容层

---

## 许可证

MIT License - 详见 [LICENSE](../LICENSE)。
