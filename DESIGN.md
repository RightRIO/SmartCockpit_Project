# 分布式任务调度监控系统设计文档

| 字段 | 内容 |
|------|------|
| **课程背景** | 分布式系统课程作业 |
| **核心关键词** | Linux · epoll · 多进程 · 事件驱动 · 任务调度 |
| **实现语言** | C++17 |
| **依赖系统** | Linux（epoll / timerfd / socketpair / fork） |
| **编译方式** | `g++ -O2 -std=c++17 scheduler.cpp -o scheduler` |

---

## 一、需求概述

### 1.1 功能需求

本系统实现一个**多进程任务调度监控系统**，由一个 Manager 进程（父进程）和 N 个 Worker 进程（子进程）组成，通过参数 N 指定 Worker 数量（3 ≤ N ≤ 10）。

| 进程 | 职责 |
|------|------|
| **Manager（父进程）** | 创建 N 个 Worker；每秒向所有 Worker 各发送一个随机任务（A/B/C）；接收 Worker 的完成响应；每 5 秒输出统计报告 |
| **Worker（子进程）** | 接收任务并处理（A 类休眠 100ms，B 类 200ms，C 类 300ms）；完成后向 Manager 发送完成消息；记录自身统计 |

### 1.2 任务类型

| 类型 | 处理时间 | 说明 |
|------|---------|------|
| A | 100 ms | 轻量任务 |
| B | 200 ms | 中量任务 |
| C | 300 ms | 重量任务 |

任务由 Manager 随机选取（A、B、C 三选一），均匀分发给所有 Worker。

---

## 二、项目结构

```
distributed-task-scheduler/
├── scheduler.cpp       # 完整源代码（单文件，约 460 行 C++）
├── Makefile           # 构建脚本（make / make test / make clean）
├── README.md          # 使用说明
├── DESIGN.md          # 本文档
└── test/
    ├── test_boundary.sh   # 边界值测试
    └── test_stress.sh     # 压力测试（Worker 全部崩溃后 Manager 存活验证）
```

**编译与运行：**

```bash
make clean && make          # 编译
./scheduler 5              # 启动 5 个 Worker
```

---

## 三、系统架构

### 3.1 整体架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                       Manager 进程（父进程）                           │
│                                                                      │
│   ┌──────────────┐    ┌───────────────┐    ┌──────────────────┐   │
│   │ SIGINT/SIGTERM│   │ SIGUSR1/SIGUSR2│    │ stdin (+/-)      │   │
│   │ 优雅退出      │    │ 增删 Worker   │    │ 键盘交互         │   │
│   └──────┬───────┘    └───────┬───────┘    └────────┬─────────┘   │
│          └───────────────────┴──────────────────────┘              │
│                              ▼                                       │
│   ┌────────────────────────────────────────────────────────────┐   │
│   │              EventLoop（事件循环中枢）                        │   │
│   │                                                              │   │
│   │   epoll_wait() ── [timerfd_1s] ──► dispatch_tasks()         │   │
│   │              ── [timerfd_5s] ──► print_statistics()         │   │
│   │              ── [socketpair FD] ─► handle_message()         │   │
│   │              ── [stdin] ──► process_stdin()                 │   │
│   └────────────────────────────────────────────────────────────┘   │
│                                                                      │
│   WorkerManager：创建/销毁 Worker · 任务分发 · 消息路由 · 统计聚合    │
└──────────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
  ┌───────────┐        ┌───────────┐        ┌───────────┐
  │ Worker 1  │        │ Worker 2  │        │ Worker N  │
  │           │        │           │        │           │
  │ recv_task │        │ recv_task │        │ recv_task │
  │  └sleep   │        │  └sleep   │        │  └sleep   │
  │  └send_done│       │  └send_done│       │  └send_done│
  │  A:100ms  │        │  A:100ms  │        │  A:100ms  │
  │  B:200ms  │        │  B:200ms  │        │  B:200ms  │
  │  C:300ms  │        │  C:300ms  │        │  C:300ms  │
  └───────────┘        └───────────┘        └───────────┘
```

### 3.2 组件职责

| 组件 | 职责 | 代码位置 |
|------|------|---------|
| `EventLoop` | 基于 epoll 的事件分发中枢，统一管理定时器、socketpair FD、stdin 的 I/O 事件 | `scheduler.cpp:423~456` |
| `WorkerManager` | Worker 生命周期管理、任务分发策略、统计聚合、故障检测 | `scheduler.cpp:160~312` |
| `IpcChannel` | 封装 socketpair，提供 send/recv 语义（RAII 自动管理 fd） | `scheduler.cpp:38~88` |
| `Worker`（子进程） | 纯执行单元：收任务 → sleep → 回报，无任何调度逻辑 | `scheduler.cpp:314~340` |

---

## 四、技术选型

### 4.1 I/O 模型：为什么用 epoll

| 方案 | FD 上限 | 时间复杂度 | 每次调用行为 |
|------|---------|-----------|------------|
| `select` | FD_SETSIZE（通常 1024） | O(n)，线性扫描所有 FD | 每次传入传出结构，内核与用户态大量内存拷贝 |
| `poll` | 无硬性上限 | O(n)，线性扫描 | 每次传入传出结构，内核与用户态大量内存拷贝 |
| **`epoll`** | 无硬性上限 | **O(1)**，只返回就绪 FD | 两阶段：`epoll_create` + `epoll_ctl` 注册，内核无需重复扫描 |

本系统选择 **`epoll`**，原因有三：

1. **O(1) 就绪通知**：`epoll_wait` 只返回已就绪的文件描述符，不遍历所有 FD。本系统中，大部分时间只有 socketpair（Worker 完成消息）和 timerfd（定时器到期）会就绪，epoll 的 O(1) 优势显著。
2. **增量注册**：运行时新增 Worker 只需 `epoll_ctl(ADD)`，无需重建整个监听集合（`select`/`poll` 每次调用都需重建）。
3. **与 `timerfd` 天然搭配**：`timerfd_create` 创建的定时器 fd 可直接加入 epoll，定时器到期触发 EPOLLIN 事件，无需额外的信号处理或轮询逻辑。

### 4.2 进程模型：为什么用多进程而非多线程

| 方案 | 优势 | 劣势 |
|------|------|------|
| 多线程（pthread） | 共享地址空间，通信简单 | 线程同步复杂（锁）、栈空间消耗、竞争条件多 |
| **多进程（fork）** | **进程隔离，独立崩溃互不影响，无需锁** | IPC 相对复杂 |

本系统选择**多进程**，原因：

- **故障隔离**：Worker 崩溃（如被外部 kill）不会影响 Manager 和其他 Worker，这符合任务调度系统的可靠性要求。
- **无锁设计**：各 Worker 独立地址空间，天然不存在数据竞争，不需要任何同步原语。
- **职责单一**：Worker 只负责"收→处理→回报"，无调度逻辑，可视为纯执行单元。

### 4.3 进程间通信：为什么用 socketpair

| 方案 | 通信模式 | 适用场景 |
|------|---------|---------|
| 管道（pipe） | 单向，一端读一端写 | 简单父子单向通信 |
| 命名管道（FIFO） | 单向，有文件系统路径 | 多进程间通信 |
| **socketpair** | **全双工，Unix Domain Socket** | **父子进程对等双向通信** |

每个 Worker 与 Manager 之间建立一对 `socketpair(AF_UNIX, SOCK_DGRAM, 0, sv)`：
- Manager 持有 `sv[0]`，注册到 epoll 监听 EPOLLIN
- Worker 持有 `sv[1]`，通过 `recv_task()` 接收任务，通过 `send_done()` 发送完成消息

选择 socketpair 的关键原因：支持**全双工通信**（同一对 fd 既可发也可收），且 SOCK_DGRAM 是无连接数据报协议，`send`/`recv` 直接走内核零拷贝路径，开销极低。

---

## 五、核心实现

### 5.1 消息协议

```cpp
struct TaskMsg {       // Manager → Worker
    char type;        // 'A' / 'B' / 'C' 或 'X'（退出）
    uint32_t seq;     // 任务序号（递增）
};

struct DoneMsg {      // Worker → Manager
    char type;        // 完成的任务类型
    uint32_t seq;     // 对应任务序号
};
```

两条消息均为 **5 字节**（`#pragma pack(1)` 保证无结构体填充），使用 `send()` / `recv()` 直接发送二进制数据，无序列化开销。

### 5.2 任务分发流程

```
t = 0s        main() 中循环调用 add_worker() 创建 N 个 Worker 进程
                    ↓
              epoll_wait() 阻塞等待 I/O 事件
                    ↓
t = 1s       timerfd_1s 到期（EPOLLIN 事件）
              → dispatch_tasks()
                  为每个 Worker 随机选一个任务类型（A/B/C）
                  发送 TaskMsg{type, seq}
                    ↓
              Worker 处理任务（100/200/300ms 休眠）
                    ↓
t = 1s+x     Worker 调用 send_done()，epoll_wait 返回 socketpair FD
              → handle_message(fd)
                  解析 DoneMsg，更新 Worker.task_count 和 type_count[]
                    ↓
t = 5s       timerfd_5s 到期（EPOLLIN 事件）
              → print_statistics()
                  汇总所有 Worker 数据，输出报告
```

### 5.3 动态调整 Worker

运行时支持两种方式增删 Worker：

| 操作 | 触发方式 | 实现 |
|------|---------|------|
| 增加 Worker | 键盘 `+` 或 `kill -SIGUSR1` | `add_worker()` → `fork()` → `socketpair` → `epoll_ctl(ADD)` |
| 减少 Worker | 键盘 `-` 或 `kill -SIGUSR2` | `remove_worker()` → `send_exit('X')` → `waitpid()` → `epoll_ctl(DEL)` |

epoll 监听集合通过 `EPOLL_CTL_ADD` / `EPOLL_CTL_DEL` 增量更新，无需重建整个集合。

### 5.4 故障检测与处理

当 `recv()` 返回 0（即对方关闭了连接）时，说明对应 Worker 已异常终止，此时将该 Worker 标记为 `alive = false`，在下次 `dispatch_tasks()` 时清理：

```cpp
if (!target->channel->recv_done(type, seq)) {
    target->alive = false;  // 标记为不活跃
    return;
}
```

清理逻辑在 `dispatch_tasks()` 开头：

```cpp
for (auto it = workers_.begin(); it != workers_.end(); ) {
    if (!it->alive || !it->channel)
        it = workers_.erase(it);  // 移除失效 Worker
    else
        ++it;
}
```

### 5.5 优雅退出

```
用户按 Ctrl+C（SIGINT）
        ↓
shutdown_handler() 设置 g_running = 0
        ↓
EventLoop::run() 退出 while(g_running) 循环
        ↓
Manager::shutdown_and_wait()
        ↓
    ① 遍历 workers_，对每个 Worker 发送 'X'（TaskMsg{'X', 0}）
    ② 遍历 workers_，对每个 Worker 调用 waitpid()（阻塞等待）
    ③ 清空 workers_，关闭所有 fd
        ↓
Manager 打印退出消息，return 0
```

关键设计：使用 `'X'` 消息退出而非 `kill` 信号，是因为消息通过 socketpair 传递，Worker 收到退出请求后**先打印自身统计，再退出**——不丢失工作记录，且优雅关闭有明确语义。

---

## 六、统计报告格式

每 5 秒输出一次统计报告：

```
========== 统计报告 (间隔 5 秒) ==========
总任务数: 25  (A:8 B:9 C:8)
各Worker任务数: W1:8 W2:9 W3:8 W4:0 W5:0
==========================================
```

报告包含：
- **总完成任务数**及各类任务分布（A/B/C 各多少）
- **各 Worker 完成任务数**，便于观察负载均衡效果

---

## 七、测试覆盖

本项目共 2 个测试用例，覆盖基本功能和容错能力：

| 测试用例 | 验证目标 |
|---------|---------|
| `test_boundary.sh` | N=3/10 正常启动；N=2/11 参数校验；无参数 Usage |
| `test_stress.sh` | 所有 Worker 被 kill -9 后 Manager 存活；无僵尸进程 |

**运行方式：**

```bash
make test      # 运行全部测试
```

---

## 八、可改进方向

以下为本系统的可改进方向，可作为课程设计报告的延伸思考：

1. **超时与重试**：当前 Worker 无响应时只标记为失效，未实现超时检测与任务重试机制。可引入 timerfd 追踪每个任务的发出时间，实现超时重试。
2. **看门狗心跳**：当前依赖 socketpair 读失败检测故障，可增加心跳机制（Worker 定期向 Manager 发 PING），更快发现卡死 Worker。
3. **结构化日志**：当前统计输出为纯文本，可改为 JSONL 格式，便于后续接入 ELK 等日志分析平台。
4. **负载均衡策略**：当前为轮询分发（每 Worker 一个任务），可改为 least-pending（选择待办数最少的 Worker），提升整体吞吐量。
5. **多机扩展**：当前为单机多进程，可通过消息队列（如 POSIX mq）将 Worker 分布到多台机器。
