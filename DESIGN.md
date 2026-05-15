# 分布式任务调度监控系统设计文档

**项目名称：** VoYah 智能座舱分布式任务调度监控系统
**作者：** VoYah Team
**日期：** 2026-05-15

---

## 一、系统概述

本系统采用 **多进程 + 事件驱动** 架构，模拟智能座舱中传感器数据处理、娱乐系统任务调度等场景下的并发任务管理。系统由一个 **Manager（调度管理器）** 进程和 N 个 **Worker（工作进程）** 组成，通过 `epoll` + `timerfd` + `socketpair` 实现高效的事件驱动通信。

---

## 二、系统架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Manager 进程 (父进程)                           │
│                                                                         │
│  ┌──────────────┐     ┌──────────────────┐     ┌───────────────────┐    │
│  │   SIGINT     │     │   SIGTERM        │     │   stdin (+/-)     │    │
│  │   (Ctrl+C)   │     │   (kill)         │     │   (键盘输入)       │    │
│  └──────┬───────┘     └────────┬─────────┘     └─────────┬─────────┘    │
│         │                      │                         │             │
│         └──────────────────────┼─────────────────────────┘             │
│                                ▼                                      │
│  ┌───────────────────────────────────────────────────────────────┐     │
│  │                      EventLoop（事件循环中枢）                    │     │
│  │                                                               │     │
│  │   epoll_wait() ─────────────────────────────────────────────►│     │
│  │                                                               │     │
│  │   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌──────────┐    │     │
│  │   │timerfd  │   │timerfd  │   │socketpair│   │ STDIN    │    │     │
│  │   │(1秒任务) │   │(5秒报告) │   │ FD列表   │   │(键盘命令) │    │     │
│  │   │ EPOLLIN │   │ EPOLLIN │   │ EPOLLIN │   │ EPOLLIN  │    │     │
│  │   └───┬─────┘   └───┬─────┘   └───┬─────┘   └───┬──────┘    │     │
│  └───────┼─────────────┼───────────┼──────────────┼────────────┘     │
│          │             │           │              │                  │
│          ▼             ▼           ▼              ▼                  │
│  ┌───────────────────────────────────────────────────────────────┐     │
│  │                    WorkerManager（调度逻辑）                     │     │
│  │                                                               │     │
│  │   • dispatch_tasks()    → 每秒向所有 Worker 分发随机任务         │     │
│  │   • handle_message(fd)  → 接收 Worker 完成任务响应，更新统计     │     │
│  │   • print_statistics()  → 每5秒输出系统状态报告                 │     │
│  │   • add/remove_worker() → 动态增删 Worker（支持 Ctrl+C 优雅退出）│     │
│  │   • graceful_shutdown()→ 向所有 Worker 发送 'X'，等待回收        │     │
│  └───────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────┘
                                 │
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │
          ▼                      ▼                      ▼
   ┌─────────────┐        ┌─────────────┐        ┌─────────────┐
   │  Worker 1   │        │  Worker 2   │        │  Worker N   │
   │   (子进程)   │        │   (子进程)   │        │   (子进程)   │
   │             │        │             │        │             │
   │ socketpair  │        │ socketpair  │        │ socketpair  │
   │    FD ←─────┼────────┼─────FD ←────┼────────┼─────FD      │
   │             │        │             │        │             │
   │ recv_task() │        │ recv_task() │        │ recv_task() │
   │  └─sleep   │        │  └─sleep   │        │  └─sleep   │
   │  └─send_done│        │  └─send_done│        │  └─send_done│
   │             │        │             │        │             │
   │ 类型A:100ms │        │ 类型A:100ms │        │ 类型A:100ms │
   │ 类型B:200ms │        │ 类型B:200ms │        │ 类型B:200ms │
   │ 类型C:300ms │        │ 类型C:300ms │        │ 类型C:300ms │
   └─────────────┘        └─────────────┘        └─────────────┘

  ────── TaskMsg (type, seq)         ────── DoneMsg (type, seq)
  ...... 'X' 退出消息                 ...... socketpair 全双工通信
```

### 架构关键设计点

1. **Manager 是事件中枢**：使用 `epoll` 统一监听 timerfd（定时）、socketpair FD（Worker 响应）、stdin（键盘命令）三类 I/O 源，避免多线程或轮询开销。
2. **Worker 是纯执行单元**：子进程只负责"收→处理→回报"三件事，无任何调度逻辑，保持职责单一。
3. **socketpair 全双工通信**：每个 Worker 与 Manager 之间拥有一对专属 socketpair FD，支持双向通信（Manager 发任务，Worker 报结果），互不阻塞。
4. **Manager 与 Worker 通过 seq 追踪任务**：每个任务携带递增序号（`next_seq_`），便于调试和任务链路追踪。

---

## 三、epoll 模型选型理由

### 3.1 为什么不用多线程？

| 方案 | 优势 | 劣势 |
|------|------|------|
| **多线程（pthread）** | 共享地址空间，通信简单 | 线程同步复杂、竞争条件多、栈空间消耗、智能座舱场景下线程切换开销大 |
| **多进程（fork）** | 进程隔离安全、独立崩溃不影响他人 | 进程间通信（IPC）复杂、开销比线程大 |

本系统选择**多进程**，原因：
- 智能座舱场景要求**高可靠性**，一个 Worker 崩溃不应影响 Manager 和其他 Worker
- Worker 彼此隔离，不会出现数据竞争（不需要锁）
- 现代 Linux 中 `fork` + `copy-on-write` 开销已大幅降低

### 3.2 为什么不用 `select` / `poll`？

| 方案 | FD 上限 | 时间复杂度 | 每次调用行为 |
|------|---------|-----------|-------------|
| `select` | FD_SETSIZE（通常 1024） | O(n)，线性扫描所有 FD | 每次传入传出结构，内核与用户态大量内存拷贝 |
| `poll` | 无硬性上限 | O(n)，线性扫描所有 FD | 每次传入传出结构，内核与用户态大量内存拷贝 |
| **`epoll`** | 无硬性上限 | O(1)，只返回就绪 FD | 两阶段：`epoll_create` + `epoll_ctl` 注册，内核无需重复扫描 |

本系统选择 **`epoll`**，原因：
- **O(1) 就绪通知**：`epoll_wait` 只返回已就绪的文件描述符，不遍历所有 FD，符合"少数活跃 FD + 大量空闲 Worker"的场景
- **增量注册**：新增 Worker 时只需 `epoll_ctl(ADD)`，无需重建监听集合
- **智能座舱实时性要求**：`epoll` 的低延迟特性（微秒级）满足座舱任务调度的实时需求
- **与 `timerfd` 天然搭配**：`timerfd` 创建的定时器文件描述符可以直接加入 epoll，实现精确的 1 秒任务分发和 5 秒统计报告

### 3.3 为什么不用 `libevent` / `libuv` 等库？

- 作业要求使用 **Linux 原生系统调用**，展示对底层 I/O 模型的深刻理解
- 本系统功能范围有限，原生 API 足够简洁，无需引入第三方依赖
- 使用 `epoll` + `timerfd` + `socketpair` 组合，完整覆盖了座舱场景所需的 I/O 多路复用、定时任务、进程间通信三种能力

---

## 四、核心数据结构

### 4.1 消息协议（固定 5 字节）

```cpp
struct TaskMsg {      // Manager → Worker：派发任务
    char   type;     // 'A'/'B'/'C' 或 'X'（退出信号）
    uint32_t seq;    // 任务序号（用于追踪）
};

struct DoneMsg {     // Worker → Manager：任务完成
    char   type;     // 完成任务类型
    uint32_t seq;    // 对应的任务序号
};
```

### 4.2 Worker 状态

```cpp
struct Worker {
    pid_t   pid;              // 子进程 PID
    unique_ptr<IpcChannel> ch;// 与该 Worker 的通信通道
    int     task_count = 0;   // 累计完成任务数
    int     type_count[3] = {0, 0, 0}; // 各类型任务计数
    bool    alive = true;     // 健康状态（故障检测）
};
```

### 4.3 定时器设计

| 定时器 | 周期 | 触发动作 |
|--------|------|---------|
| `timerfd_1s_` | 1 秒 | `dispatch_tasks()` — 向所有存活 Worker 各发 1 个随机任务 |
| `timerfd_5s_` | 5 秒 | `print_statistics()` — 输出系统统计报告 |

使用 `timerfd` 而非 `alarm` 或 `setitimer`：精度达纳秒级（`itimerspec`），且可与 `epoll` 无缝集成，无需信号处理。

---

## 五、关键流程说明

### 5.1 任务分发流程

```
t=0: Manager 启动，创建 N 个 Worker 进程，每个持有独立 socketpair FD
t=1s: timerfd_1s 触发 → dispatch_tasks()
        ↓
    for each alive Worker:
        seq = next_seq_++
        type = random{A, B, C}
        send_task(type, seq)
        （通过 socketpair SOCK_DGRAM 发送，零拷贝）
t=1s+x: Worker 处理任务（100/200/300ms 休眠）
        ↓
    send_done(type, seq)  （发回 Manager）
t=1s+x+δ: epoll_wait 返回就绪 FD
        ↓
    handle_message(fd)
        ↓
    更新对应 Worker 的 task_count 和 type_count
t=5s: timerfd_5s 触发 → print_statistics()
        ↓
    汇总所有 Worker 数据，输出报告
```

### 5.2 优雅退出流程（Graceful Shutdown）

```
用户按 Ctrl+C（发送 SIGINT）
        ↓
signal_handler 捕获，设置 g_running = false
        ↓
EventLoop::run() 退出 while(g_running) 循环
        ↓
Manager 遍历 workers_，对每个 Worker 调用 send_exit()（发送 'X'）
        ↓
各 Worker 收到 'X'，打印自身统计，退出 worker_main()
        ↓
Manager 遍历 workers_，对每个 Worker 调用 waitpid()
        ↓
所有子进程回收，fd 关闭，无僵尸进程
        ↓
Manager 进程 exit(0)
```

---

## 六、动态调整机制

| 操作 | 触发方式 | 实现 |
|------|---------|------|
| 增加 Worker | 键盘 `+` 或 `kill -SIGUSR1` | `add_worker()` → `fork()` → 创建 socketpair → `epoll_ctl(ADD)` |
| 减少 Worker | 键盘 `-` 或 `kill -SIGUSR2` | `remove_worker()` → `send_exit()` → `waitpid()` → `epoll_ctl(DEL)` |
| 故障自愈 | Worker 无响应（`recv` 返回 0） | `remove_worker_by_fd()` → 标记 `alive=false` → 等待下次 `dispatch` 时清理 |

---

## 七、运行说明

```bash
# 编译
g++ -O2 -std=c++17 scheduler.cpp -o scheduler

# 运行（启动 5 个 Worker）
./scheduler 5

# 运行中交互
+    → 增加 1 个 Worker
-    → 减少 1 个 Worker（最少保留 1 个）
Ctrl+C → 优雅退出（发送 'X' 给所有 Worker，等待回收）
```

---

## 八、设计优势总结

| 特性 | 实现方式 | 智能座舱价值 |
|------|---------|-------------|
| **进程隔离** | `fork()` 多进程 | 单个传感器任务崩溃不影响整体系统 |
| **O(1) I/O 多路复用** | `epoll` | 高并发下仍保持低延迟 |
| **精确定时** | `timerfd_create` | 任务调度周期精确可控 |
| **零拷贝通信** | `socketpair` SOCK_DGRAM | 进程间通信高效 |
| **优雅退出** | SIGINT 捕获 + 'X' 消息 | 系统关闭时任务不丢失、无僵尸 |
| **动态伸缩** | 运行时 + / - | 根据座舱负载动态调整处理能力 |
| **无锁设计** | 进程隔离天然避免竞争 | 消除死锁风险 |
