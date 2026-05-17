# VoYah 分布式任务调度监控系统 - 设计文档

**项目名称：** VoYah 智能座舱分布式任务调度监控系统
**版本：** v1.0.0
**作者：** RightRIO
**日期：** 2026-05-15
**状态：** 稳定版

---

## 目录

- [一、系统概述](#一系统概述)
- [二、系统架构](#二系统架构)
- [三、epoll 模型选型](#三epoll-模型选型)
- [四、核心数据结构](#四核心数据结构)
- [五、关键流程](#五关键流程)
- [六、动态调整机制](#六动态调整机制)
- [七、容错与自愈](#七容错与自愈)
- [八、运行说明](#八运行说明)
- [九、设计优势总结](#九设计优势总结)

---

## 一、系统概述

本系统采用 **多进程 + 事件驱动** 架构，模拟智能座舱中传感器数据处理、娱乐系统任务调度等场景下的并发任务管理。系统由一个 **Manager（调度管理器）** 进程和 N 个 **Worker（工作进程）** 组成，通过 `epoll` + `timerfd` + `socketpair` 实现高效的事件驱动通信。

**版本历史**

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0.0 | 2026-05-15 | 初始稳定版发布 |
| Unreleased | - | 多语言文档、CI/CD |

---

## 二、系统架构

```
Manager 进程（父进程）
 +- EventLoop（epoll 中枢）
     +- timerfd 1s  -> dispatch_tasks + check_timeouts
     +- timerfd 2s  -> send_ping + check_heartbeat
     +- timerfd 5s  -> print_statistics（每 5 秒输出系统报告）
     +- stdin        -> 键盘命令（+ / - / s / i / p / q）
         |
         v
     Worker 1 (fork)  -- socketpair -- Worker 2 (fork)  -- ... -- Worker N (fork)
```

### 架构关键设计点

1. **Manager 是事件中枢**：使用 `epoll` 统一监听 timerfd（定时）、socketpair FD（Worker 响应）、stdin（键盘命令）三类 I/O 源。
2. **Worker 是纯执行单元**：子进程只负责"收->处理->回报/心跳"三件事，无任何调度逻辑。
3. **socketpair 全双工通信**：每个 Worker 与 Manager 之间拥有一对专属 socketpair FD，支持双向通信。
4. **心跳看门狗**：2 秒 ping / 6 秒超时，超时自动替换故障 Worker。
5. **任务超时重试**：任务 5 秒未完成自动重试（最多 2 次），超过最大重试次数标记失败。
6. **JSONL 结构化日志**：每次事件（派发、完成、超时、失败、心跳等）均写入带时间戳的 JSONL 文件。

---

## 三、epoll 模型选型

### 3.1 为什么不用多线程？

| 方案 | 优势 | 劣势 |
|------|------|------|
| **多线程（pthread）** | 共享地址空间，通信简单 | 线程同步复杂、竞争条件多、栈空间消耗大 |
| **多进程（fork）** | 进程隔离安全、独立崩溃不影响他人 | 进程间通信（IPC）复杂、开销比线程大 |

本系统选择**多进程**，原因：
- 智能座舱场景要求**高可靠性**，一个 Worker 崩溃不应影响 Manager 和其他 Worker
- Worker 彼此隔离，不会出现数据竞争（不需要锁）
- 现代 Linux 中 `fork` + **Copy-on-Write** 开销已大幅降低

### 3.2 为什么不用 `select` / `poll`？

| 方案 | FD 上限 | 时间复杂度 | 每次调用行为 |
|------|---------|-----------|-------------|
| `select` | FD_SETSIZE（通常 1024）| O(n)，线性扫描所有 FD | 内核与用户态大量内存拷贝 |
| `poll` | 无硬性上限 | O(n)，线性扫描所有 FD | 内核与用户态大量内存拷贝 |
| **`epoll`** | 无硬性上限 | **O(1)，只返回就绪 FD** | 两阶段：注册一次，增量管理 |

本系统选择 **`epoll`**，原因：
- **O(1) 就绪通知**：`epoll_wait` 只返回已就绪的文件描述符
- **增量注册**：新增 Worker 时只需 `epoll_ctl(ADD)`
- **智能座舱实时性**：`epoll` 微秒级延迟满足座舱任务调度的实时需求
- **`timerfd` 天然搭配**：`timerfd` 创建的定时器 FD 可直接加入 epoll

### 3.3 为什么不用 `libevent` / `libuv`？

- 作业要求使用 **Linux 原生系统调用**，展示对底层 I/O 模型的深刻理解
- 本系统功能范围有限，原生 API 足够简洁，无需引入第三方依赖
- 使用 `epoll` + `timerfd` + `socketpair` 组合，完整覆盖 I/O 多路复用、定时任务、进程间通信三种能力

---

## 四、核心数据结构

### 4.1 消息协议（固定 5 字节，`#pragma pack(1)`）

```cpp
struct TaskMsg {
    char   type;     // 'A'/'B'/'C'（任务）|'X'（退出）|'P'（心跳）
    uint32_t seq;   // 任务序号（用于追踪，重试后生成新序号）
};
```

| 消息类型 | 方向 | type 值 | seq 含义 |
|---------|------|---------|---------|
| 任务 A/B/C | Manager -> Worker | 'A'/'B'/'C' | 任务序号 |
| 退出 | Manager -> Worker | 'X' | 0（忽略）|
| 心跳 Ping | Manager -> Worker | 'P' | 0（忽略）|
| 任务完成 / Pong | Worker -> Manager | 对应类型 | 对应任务序号 |

### 4.2 Worker 状态

```cpp
struct Worker {
    pid_t   pid;                        // 子进程 PID
    std::unique_ptr<IpcChannel> ch;   // 与该 Worker 的通信通道
    int     task_count = 0;            // 累计完成任务数
    int     type_count[3] = {0,0,0};  // 各类型任务计数 [A,B,C]
    bool    alive = true;               // 健康状态
    int     pending_count = 0;          // 当前待处理任务数（用于负载均衡）
    int64_t start_time_ms = 0;        // 启动时间戳（毫秒）
    int64_t last_heartbeat_ms = 0;    // 最后心跳时间戳
};
```

### 4.3 定时器设计

| 定时器 | 周期 | 触发动作 |
|--------|------|---------|
| `timerfd_1s_` | 1 秒 | `dispatch_tasks()` + `check_timeouts()` |
| `timerfd_2s_` | 2 秒 | `send_ping_to_all()` + `check_heartbeat()` |
| `timerfd_5s_` | 5 秒 | `print_statistics()` 输出系统报告 |

使用 `timerfd` 而非 `alarm` 或 `setitimer`：精度达纳秒级（`itimerspec`），且可与 `epoll` 无缝集成。

---

## 五、关键流程

### 5.1 任务分发流程

```
t=0:   Manager 启动，创建 N 个 Worker 进程，每个持有独立 socketpair FD
t=1s:  timerfd_1s 触发 -> dispatch_tasks()
         v
       for each alive Worker (按 pending_count 升序，即最少待办优先):
           seq = next_seq_++
           type = random{A, B, C}
           send_task(type, seq)
           task_tracker_[seq] = {type, seq, now_ms, pid}
           pending_count++
           total_dispatched++
t=1s+x: Worker 处理任务（100/200/300ms 休眠）-> send_done(type, seq)
t=1s+x+δ: epoll_wait 返回就绪 FD -> handle_message(fd)
         v
       更新 Worker 的 task_count、type_count、pending_count--
       记录延迟：latency = now_ms - dispatch_time_ms
t=2s:  timerfd_2s 触发 -> send_ping_to_all() -> Worker 回复 Pong
t=5s:  timerfd_5s 触发 -> print_statistics() 输出报告
```

### 5.2 任务超时重试流程

```
任务派发后 -> tracker_[seq] = {dispatch_time_ms, retry_count=0}
     v
每 1 秒 check_timeouts():
     elapsed = now_ms - dispatch_time_ms
     if elapsed > 5s:
         if retry_count < 2:
             retry_queue_.push({type, seq})
             total_timeout++
         else:
             total_failed++
         tracker_.erase(seq)
     v
dispatch_retries():
     从 retry_queue_ 取任务 -> 发到 pending_count 最少的 Worker
     生成新 seq（新任务），tracker_[new_seq] = {retry_count=1}
     total_retry++
```

### 5.3 心跳看门狗流程

```
每 2 秒 send_ping_to_all():
     向所有 Worker 发 'P' 消息
     v
Worker 收到 'P' -> 回复 Pong -> Manager 更新 last_heartbeat_ms
     v
每 2 秒 check_heartbeat():
     for each Worker:
         elapsed = now_ms - last_heartbeat_ms
         if elapsed > 6s:
             [WATCHDOG] Worker PID=X 超时，触发自动替换
             replace_worker(idx)
             v
replace_worker(idx):
     收集该 Worker 所有 pending 任务 -> 推入 retry_queue_
     关闭旧 fd，waitpid(WNOHANG) 回收
     fork() 新 Worker，建立新 socketpair
     epoll_ctl(ADD) 注册新 FD
     dispatch_retries() 重新派发营救任务
```

### 5.4 优雅退出流程

```
用户按 Ctrl+C（发送 SIGINT）
        v
signal_handler -> g_running = false
        v
EventLoop::run() 退出 while(g_running) 循环
        v
Manager 遍历 workers_，对每个 Worker 调用 send_exit()（发送 'X'）
        v
各 Worker 收到 'X'，打印自身统计，exit(0)
        v
Manager 遍历 workers_，对每个 Worker 调用 waitpid()
        v
所有子进程回收，fd 关闭，无僵尸进程
        v
Manager 进程 exit(0)
```

---

## 六、动态调整机制

| 操作 | 触发方式 | 实现 |
|------|---------|------|
| 增加 Worker | 键盘 `+` 或 `kill -SIGUSR1` | `add_worker()` -> `fork()` -> 创建 socketpair -> `epoll_ctl(ADD)` |
| 减少 Worker | 键盘 `-` 或 `kill -SIGUSR2` | `remove_worker()` -> `send_exit()` -> `waitpid()` -> `epoll_ctl(DEL)` |
| 故障替换 | Worker 无响应（`recv` 返回 0 或心跳超时） | `replace_worker()` -> 营救 pending 任务 -> fork 新 Worker |
| 优雅退出 | 键盘 `q`、`Ctrl+C` 或 `kill -SIGINT` | `shutdown_and_wait()` -> 向所有发 'X' -> waitpid 回收 |

---

## 七、容错与自愈

### 7.1 故障场景与处理

| 故障场景 | 检测方式 | 处理方式 |
|---------|---------|---------|
| Worker 崩溃（被 kill）| `recv` 返回 0（EOF）| `remove_worker_by_fd()` -> `replace_worker()` |
| Worker 假死（不处理任务）| 任务 5 秒超时 | 进入重试队列，派发到其他 Worker |
| Worker 无心跳响应 | 6 秒无 Pong | `check_heartbeat()` -> `replace_worker()` |
| socketpair 写失败 | `send` 返回 < 0 | `replace_worker()` |
| 所有 Worker 同时崩溃 | 同上 | Manager 独立存活，继续调度（Worker 数为 0 时跳过调度）|

### 7.2 任务不丢失保证

当 Worker 被替换时，`replace_worker()` 会：
1. 扫描 `task_tracker_`，找出所有 `target_pid == old_pid` 的任务
2. 将这些任务推入 `retry_queue_`
3. 新 Worker 启动后，`dispatch_retries()` 立即重新派发这些任务
4. 同一任务最多经历 2 次重试，超过则标记 `total_failed`

---

## 八、运行说明

```bash
# 编译
make

# 帮助
./bin/scheduler --help

# 版本
./bin/scheduler --version

# 运行（启动 5 个 Worker）
./bin/scheduler 5

# 运行中交互
+     -> 增加 1 个 Worker
-     -> 减少 1 个 Worker（最少保留 1 个）
s/S   -> 立即打印统计报告
i/I   -> 打印 Worker 详细信息
p/P   -> 打印待追踪任务列表
q/Q   -> 优雅退出（与 Ctrl+C 等效）
Ctrl+C -> 优雅退出
```

---

## 九、设计优势总结

| 特性 | 实现方式 | 智能座舱价值 |
|------|---------|-------------|
| **进程隔离** | `fork()` 多进程 | 单个传感器任务崩溃不影响整体系统 |
| **O(1) I/O 多路复用** | `epoll` | 高并发下仍保持低延迟 |
| **精确定时** | `timerfd_create` | 任务调度周期精确可控 |
| **零拷贝通信** | `socketpair` SOCK_DGRAM | 进程间通信高效 |
| **优雅退出** | SIGINT 捕获 + 'X' 消息 | 系统关闭时无僵尸 |
| **动态伸缩** | 运行时 + / - | 根据座舱负载动态调整处理能力 |
| **无锁设计** | 进程隔离天然避免竞争 | 消除死锁风险 |
| **心跳看门狗** | 2s ping / 6s timeout | 故障自动检测与替换 |
| **超时重试** | 5s timeout / max 2 retries | 网络抖动时任务不丢失 |
| **结构化日志** | JSONL 带时间戳 | 事后分析和问题定位 |

---

## 附录：退出码

| 退出码 | 含义 |
|--------|------|
| `0` | 正常退出（优雅退出或 --help / --version）|
| `64` | 命令行参数错误（缺少参数、N 超出范围）|
| `70` | 运行时错误（fork 失败、socketpair 失败、epoll_create 失败）|
