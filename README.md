# 分布式任务调度监控系统

## 项目结构

```
distributed-task-scheduler/
├── scheduler.cpp           # 完整源代码（单文件，约 460 行 C++）
├── Makefile               # 构建脚本（make / make test / make clean）
├── DESIGN.md              # 技术方案设计文档
├── README.md              # 本文件
└── test/
    ├── test_boundary.sh        # 边界值测试
    └── test_stress.sh          # 压力测试（Worker 全部故障）
```

## 整体架构

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Manager 进程（父进程）                             │
│                                                                          │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────┐             │
│  │SIGINT/SIGTERM│  │SIGUSR1/SIGUSR2│   │ stdin (+/-)       │             │
│  │ 优雅退出      │  │ 增删 Worker   │   │ 键盘交互         │             │
│  └──────┬───────┘  └───────┬───────┘   └────────┬─────────┘             │
│         └───────────────────┴──────────────────────┘                     │
│                             ▼                                             │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │               EventLoop（事件循环中枢）                          │    │
│  │                                                                │    │
│  │   epoll_wait() ── [timerfd_1s] ──► dispatch_tasks()           │    │
│  │              ── [timerfd_5s] ──► print_statistics()           │    │
│  │              ── [socketpair FD] ──► handle_message()           │    │
│  │              ── [stdin] ──► process_stdin()                   │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  WorkerManager：创建/销毁 Worker · 任务分发 · 消息路由 · 统计聚合          │
└──────────────────────────────────────────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
  ┌───────────┐        ┌───────────┐        ┌───────────┐
  │ Worker 1  │        │ Worker 2  │        │ Worker N  │
  │           │        │           │        │           │
  │ recv_task │        │ recv_task │        │ recv_task │
  │  └sleep  │        │  └sleep  │        │  └sleep  │
  │  └send_done│       │  └send_done│       │  └send_done│
  │  A:100ms  │        │  A:100ms  │        │  A:100ms  │
  │  B:200ms  │        │  B:200ms  │        │  B:200ms  │
  │  C:300ms  │        │  C:300ms  │        │  C:300ms  │
  └───────────┘        └───────────┘        └───────────┘
```

**架构说明：**

| 组件 | 说明 |
|------|------|
| `EventLoop` | 基于 `epoll` 的事件分发中枢，统一管理定时器、socketpair、stdin 的 I/O 事件 |
| `WorkerManager` | Worker 生命周期管理、任务分发策略、统计聚合、故障检测 |
| `IpcChannel` | 封装 `socketpair`，提供 send/recv 语义（RAII 自动管理 fd） |
| `Worker`（子进程） | 纯执行单元：收任务 → sleep → 回报，无任何调度逻辑 |

## 快速开始

```bash
# 编译
make

# 运行（启动 N 个 Worker，3 ≤ N ≤ 10）
./scheduler 5

# 运行测试
make test

# 清理
make clean
```

## 交互命令

运行期间可在终端输入：

| 按键 | 作用 |
|------|------|
| `+` | 动态增加 1 个 Worker（最多 10 个） |
| `-` | 动态减少 1 个 Worker（最少保留 1 个） |
| `Ctrl+C` | 优雅退出（向所有 Worker 发退出消息，等待回收，无僵尸进程） |

外部信号方式：

```bash
kill -SIGUSR1 $(pidof scheduler)   # 增加 Worker
kill -SIGUSR2 $(pidof scheduler)   # 减少 Worker
kill -SIGINT  $(pidof scheduler)   # 优雅退出
```

## 任务类型

| 类型 | 处理时间 | 说明 |
|------|---------|------|
| A | 100 ms | 轻量任务 |
| B | 200 ms | 中量任务 |
| C | 300 ms | 重量任务 |

任务由 Manager 随机选取，均匀分发给所有 Worker。

## 核心设计

| 技术选型 | 说明 |
|---------|------|
| `epoll` | O(1) 就绪通知，只返回活跃 FD；运行时增删 Worker 只需 `epoll_ctl(ADD/DEL)`，无需重建监听集合 |
| `timerfd` | 纳秒精度定时器，与 epoll 无缝集成：定时器到期触发 EPOLLIN 事件，无需信号或轮询 |
| `socketpair` | 全双工 Unix Domain Socket，SOCK_DGRAM 零拷贝；每个 Worker 与 Manager 独立一对 fd |
| `多进程` | Worker 崩溃不影响 Manager；独立地址空间，无锁、无数据竞争；`waitpid()` 回收防止僵尸进程 |
| `优雅退出` | 使用 `'X'` 消息退出而非 `kill` 信号，Worker 先打印自身统计再退出，不丢失工作记录 |

## 编译依赖

- Linux（需要 `epoll`、`timerfd`、`socketpair`）
- GCC 7+ 或 Clang（支持 C++17）
- GNU Make
