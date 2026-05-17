# VoYah 智能座舱分布式任务调度监控系统

## 技术方案设计文档

| 字段 | 内容 |
|------|------|
| **项目名称** | VoYah 智能座舱分布式任务调度监控系统 |
| **作者** | VoYah Team |
| **日期** | 2026-05-15 |
| **课程背景** | 训练营课程作业 |
| **核心关键词** | Linux I/O 多路复用 · 多进程架构 · 事件驱动 · 智能座舱 · 故障自愈 |

---

## 一、项目背景与目标

### 1.1 场景引入

在现代智能座舱中，传感器数据处理、娱乐系统、导航渲染等任务并发运行，任何一个模块的异常都不应影响整车控制系统的稳定性。这就要求任务调度系统必须具备**进程级隔离**能力。

本项目的目标，是实现一个**可观测、可伸缩、故障自愈**的分布式任务调度系统，模拟以下三个典型座舱任务场景：

| 任务类型 | 模拟耗时 | 典型业务场景 |
|---------|---------|------------|
| 类型 A（轻量） | 100 ms | 温度传感器数据采集 |
| 类型 B（中量） | 200 ms | 语音识别结果处理 |
| 类型 C（重量） | 300 ms | 导航地图渲染分片 |

### 1.2 核心设计目标

1. **高可靠**：单个 Worker 崩溃不影响 Manager 和其他 Worker
2. **可观测**：实时统计吞吐量、延迟、任务分布，输出 JSONL 结构化日志
3. **动态伸缩**：运行时动态增删 Worker，适应座舱负载变化
4. **优雅退出**：关闭时确保任务不丢失、无僵尸进程
5. **精确调度**：基于 `timerfd` 实现毫秒级精度的定时任务分发

---

## 二、系统架构

### 2.1 整体架构

系统采用**多进程 + 事件驱动**模型，由一个 Manager（父进程）和 N 个 Worker（子进程）组成，N 的合法范围为 `[3, 10]`。

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Manager 进程（父进程）                          │
│                                                                      │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────────────────┐  │
│  │ SIGINT     │  │ SIGUSR1/2  │  │ stdin (+/-/q/i/p)           │  │
│  │ 优雅退出    │  │ 增删Worker │  │ 键盘交互命令                 │  │
│  └─────┬──────┘  └─────┬──────┘  └──────────────┬──────────────┘  │
│        └────────────────┼───────────────────────┘                  │
│                         ▼                                          │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                 EventLoop（事件循环中枢）                        │  │
│  │                                                              │  │
│  │   epoll_wait() → [timerfd_1s|事件] → dispatch_tasks()       │  │
│  │               → [timerfd_2s|事件] → 心跳检测/看门狗           │  │
│  │               → [timerfd_5s|事件] → print_statistics()       │  │
│  │               → [socketpair|事件] → handle_message()          │  │
│  │               → [stdin|事件]    → process_stdin()             │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  WorkerManager：任务分发 · 故障检测 · 统计聚合 · 动态伸缩              │
└──────────────────────────────────────────────────────────────────────┘
                                    │
           ┌────────────────────────┼────────────────────────┐
           │                        │                        │
           ▼                        ▼                        ▼
    ┌─────────────┐          ┌─────────────┐          ┌─────────────┐
    │  Worker 1   │          │  Worker 2   │          │  Worker N   │
    │  (子进程)    │          │  (子进程)    │          │  (子进程)    │
    │             │          │             │          │             │
    │ recv_task()│          │ recv_task()│          │ recv_task()│
    │  └─sleep   │          │  └─sleep   │          │  └─sleep   │
    │  └─send_done│          │  └─send_done│          │  └─send_done│
    │ A:100ms    │          │ A:100ms    │          │ A:100ms    │
    │ B:200ms    │          │ B:200ms    │          │ B:200ms    │
    │ C:300ms    │          │ C:300ms    │          │ C:300ms    │
    └─────────────┘          └─────────────┘          └─────────────┘
```

### 2.2 组件职责

| 组件 | 职责 |
|------|------|
| **EventLoop** | 基于 epoll 的事件分发中枢，统一管理定时器、socketpair FD 和 stdin 的 I/O 事件 |
| **WorkerManager** | 任务分发策略、Worker 生命周期管理、统计聚合、故障自愈 |
| **IpcChannel** | 封装 socketpair，提供 send_msg/recv_msg 语义 |
| **Worker（子进程）** | 纯执行单元：收任务 → 处理（sleep） → 回报，无调度逻辑 |

---

## 三、技术选型：为什么用 epoll + 多进程

### 3.1 I/O 模型对比

| 方案 | FD 上限 | 时间复杂度 | 适用场景 |
|------|---------|-----------|---------|
| `select` | FD_SETSIZE（通常 1024） | O(n)，线性扫描 | 不推荐 |
| `poll` | 无硬性上限 | O(n)，线性扫描 | 不推荐 |
| **`epoll`** | 无硬性上限 | **O(1)**，只返回就绪 FD | **生产级首选** |
| `libevent` / `libuv` | 无 | O(1) | 框架选型，非本项目目标 |

**选择 epoll 的理由：**

本系统中，大部分时间是**少量 FD 就绪**（Worker 完成任务时才响应），`epoll_wait` 只返回已就绪的 FD，无需遍历所有监听项。这是典型的 "大量空闲 FD + 少数活跃 FD" 场景，epoll 的 O(1) 优势得以充分发挥。

此外，`epoll` 与 `timerfd` 天然兼容：定时器到期会触发 EPOLLIN 事件，无需额外的信号处理或轮询。

### 3.2 多进程 vs. 多线程

智能座舱场景对**可靠性**要求极高——某个传感器处理模块崩溃，不应影响整车系统。

- **多线程**：共享地址空间，通信简单，但存在数据竞争，需要锁，开销在精确实时场景下不可忽视
- **多进程**：进程隔离，独立崩溃互不影响；`fork` + copy-on-write 开销在现代 Linux 中已大幅降低；无需锁，天然无数据竞争

本系统选择**多进程**，并将 Worker 设计为纯执行单元（无调度逻辑），实现"**故障隔离 + 无锁设计**"。

### 3.3 进程间通信：为什么用 socketpair

| 方案 | 通信模式 | 适用场景 |
|------|---------|---------|
| 管道（pipe） | 单向 | 简单父子通信 |
| 消息队列（msgget） | 需内核管理 | 多进程消息传递 |
| 共享内存（shmget） | 需同步 | 大数据量共享 |
| **socketpair** | **全双工、SOCK_DGRAM** | **父子进程对等通信** |

每个 Worker 与 Manager 之间建立一对 `socketpair(AF_UNIX, SOCK_DGRAM, 0, sv)`，Manager 持 `sv[0]`，Worker 持 `sv[1]`。SOCK_DGRAM 是无连接数据报协议，`send`/`recv` 直接映射到内核的零拷贝路径，开销极低，且天然支持双向通信。

---

## 四、核心功能实现

### 4.1 任务分发与追踪

```
timerfd_1s（每秒到期）
  → dispatch_tasks()
      为每个 alive Worker 分配一个随机任务（A/B/C）
      seq = next_seq_++（全局递增序号）
      记录到 task_tracker_（seq → TaskRecord 映射）
      写入 jsonl：{"event":"dispatch","seq":...,"type":"A","target_pid":...}

Worker 完成任务（socketpair EPOLLIN）
  → handle_message(fd)
      从 seq 查找 TaskRecord，计算延迟
      更新 Worker.task_count / type_count[0~2]
      更新全局统计（total_completed、latency_sum_ms）
      写入 jsonl：{"event":"complete","seq":...,"latency_ms":...}
```

关键设计：使用**递增序号 seq** 作为任务链路追踪的唯一 ID。`task_tracker_`（`unordered_map<uint32_t, TaskRecord>`）在派发时写入，在完成/超时时删除，保证每个任务只被处理一次。

### 4.2 动态增删 Worker

| 操作 | 触发方式 | 实现路径 |
|------|---------|---------|
| 增加 Worker | 键盘 `+` 或 `kill -SIGUSR1` | `add_worker()` → `fork()` → `socketpair` → `epoll_ctl(ADD)` |
| 减少 Worker | 键盘 `-` 或 `kill -SIGUSR2` | `remove_worker()` → `send('X')` → `waitpid()` → `epoll_ctl(DEL)` |

动态增删时，`epoll` 监听集合通过 `EPOLL_CTL_ADD` / `EPOLL_CTL_DEL` 增量更新，无需重建，这是相比 `select`/`poll` 的重要优势。

### 4.3 故障自愈机制（Watchdog）

系统实现了两层故障检测：

**层一：socketpair 读失败**
- `recv()` 返回 0 表示对方关闭了连接（Worker 被 kill）
- `remove_worker_by_fd(fd)` 触发，自动替换新 Worker，并将未完成任务重新入 `retry_queue_`

**层二：心跳超时看门狗（`check_heartbeat`）**
- `timerfd_2s` 每 2 秒触发一次
- 遍历所有 Worker，若 `now_ms - last_heartbeat_ms > HEARTBEAT_TIMEOUT_SECS(6s)`，判定为卡死，触发替换
- 心跳基于 Worker 每次响应消息时更新的 `last_heartbeat_ms`

### 4.4 超时与重试

- `timerfd_1s` 同时触发 `check_timeouts()`
- 遍历 `task_tracker_`，若任务等待时间 > `TIMEOUT_SECS(5s)`：
  - `retry_count < MAX_RETRIES(2)`：推入 `retry_queue_`，后续 `dispatch_retries()` 重新派发
  - `retry_count >= MAX_RETRIES`：标记为 `failed`，从 tracker 移除
- 重试任务会选择 `pending_count` 最少的 Worker（**least-pending 负载均衡**）

### 4.5 优雅退出

```
SIGINT / SIGTERM 捕获
  → 设置 g_running = false
  → EventLoop::run() 退出事件循环
  → WorkerManager::shutdown_and_wait()
      1. 向所有 alive Worker 发送 TASK_EXIT('X')
      2. 遍历所有 Worker 调用 waitpid()（阻塞等待）
      3. 关闭所有 fd
  → Manager exit(0)
```

关键设计：使用 **'X' 消息** 而非 `kill` 信号，是因为消息可以通过 socketpair 传递，Worker 可以在收到退出请求后**先打印自身统计，再优雅退出**——不丢失已完成的工作记录。

---

## 五、可观测性设计

### 5.1 统计报告（每 5 秒）

```
========== 系统统计报告 (每5秒) ==========
系统运行时间: 12s  |  总派发: 48  |  吞吐量: 4.0 tasks/s
已完成: 47  |  超时: 1  |  重试: 1  |  失败: 0
-------------------------------------------
Worker   存活    存活时间    完成任务    A      B      C    待处理
  W1    [YES]    12s        16       5     6     5      0
  W2    [YES]    12s        16       6     5     5      0
  W3    [YES]    12s        15       5     5     5      0
-------------------------------------------
任务延迟: avg=152ms  min=100ms  max=301ms
===========================================
```

### 5.2 JSONL 结构化日志

每条日志为合法 JSON Lines 格式：

```jsonl
{"event":"worker_add","pid":12345,"worker_count":4,"time_ms":1747593600123}
{"event":"dispatch","seq":1,"type":"A","target_pid":12345,"pending":1,"time_ms":1747593601000}
{"event":"complete","seq":1,"type":"A","target_pid":12345,"latency_ms":103,"time_ms":1747593601103}
{"event":"timeout","seq":5,"type":"C","target_pid":12346,"retry":1,"elapsed_ms":5012,"time_ms":1747593605012}
{"event":"pong","from_pid":12345,"time_ms":1747593608000}
```

JSONL 格式的优势：可逐行追加、无需锁、支持 `jq` 快速查询，便于后续接入 ELK / Loki 等日志分析系统。

---

## 六、测试覆盖

本项目构建了 9 个独立测试用例，覆盖多个维度：

| 测试用例 | 验证目标 |
|---------|---------|
| `test_boundary.sh` | N=3/10 正常启动；N=2/11 参数校验；无参数 Usage |
| `test_stress.sh` | 所有 Worker 被 kill -9 后 Manager 存活、无僵尸进程 |
| `test_dynamic.sh` | SIGUSR1/2 增删 Worker；上限 10 拒绝；下限 1 拒绝 |
| `test_signal.sh` | SIGINT/SIGTERM 优雅退出；SIGUSR1/2 增减 Worker |
| `test_timeout_retry.sh` | SIGSTOP 触发超时；重试次数上限验证；Manager 存活 |
| `test_perf.sh` | 吞吐量 >= 10 tasks（5 Worker）；延迟 avg < 1000ms |
| `test_concurrent.sh` | 快速连续信号；混合并发；极限压力（20 次 SIGUSR1） |
| `test_graceful.sh` | exit code=0；Worker EXIT 日志；连续启停无僵尸 |
| `test_jsonl.sh` | JSON 合法性（jq 验证）；event 字段覆盖；time_ms 格式 |

运行方式：`make test`（全部）或 `make test-quick`（smoke test）

---

## 七、性能指标

基于 5 个 Worker、12 秒运行的实测数据参考：

| 指标 | 参考值 | 说明 |
|------|-------|------|
| 吞吐量 | 4~5 tasks/s | 每秒派发数 = Worker 数量（每个 Worker 1 task/s） |
| 平均延迟 | 100~200 ms | 接近类型 A（100ms）的理论值，说明负载均衡有效 |
| 最大延迟 | < 500 ms | 受类型 C（300ms）+ 排队影响，仍在合理范围 |
| 启动时间 | < 1 s | fork + socketpair + epoll 注册，毫秒级 |
| 内存占用 | ~2 MB | 每个 Worker 约 200KB（轻量子进程） |

---

## 八、技术亮点总结

| 维度 | 实现方案 | 面试可展开点 |
|------|---------|------------|
| **I/O 模型** | epoll O(1) 就绪通知 | 解释 LT/ET 模式、边缘触发注意事项 |
| **进程管理** | fork + waitpid 回收 | 详解 SIGCHLD 处理、WAIT PID 参数 |
| **定时器** | timerfd_create + itimerspec | 解释纳秒精度、与 epoll 的集成方式 |
| **IPC** | socketpair SOCK_DGRAM | 解释零拷贝、全双工、与管道的区别 |
| **故障自愈** | recv=0 检测 + 看门狗 | 解释为什么要两层检测、epoll 事件驱动特性 |
| **优雅退出** | 'X' 消息 + waitpid | 解释为什么要用消息而非 kill 信号 |
| **负载均衡** | least-pending 策略 | 解释选择原因、实现方式、与其他策略的权衡 |
| **可观测性** | JSONL 日志 | 解释为何选 JSONL 而非其他格式（追加写入、无锁） |

---

## 九、可改进方向（面试时可主动提及）

1. **高可用**：引入 Master/Slave Manager 双进程热备，解决 Manager 本身的单点故障
2. **持久化**：将 JSONL 日志替换为 WAL（Write-Ahead Log），支持崩溃恢复后的任务续做
3. **优先级队列**：当前任务全为随机分配，可引入 `priority` 字段，支持关键任务（如安全气囊信号）优先调度
4. **资源限制**：为每个 Worker 设置 cgroup 资源上限，防止异常 Worker 耗尽系统资源
5. **分布式扩展**：当前为单机多进程，可通过消息队列（如 ZeroMQ）扩展为多机集群
