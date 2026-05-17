# VoYah 系统设计文档

## 概述

VoYah 是一个面向智能座舱场景的高可靠、事件驱动型分布式任务调度系统，采用 epoll I/O 多路复用 + 多进程架构，支持运行时动态扩缩容、故障自愈、优雅退出等特性，适用于 Linux 嵌入式座舱环境。

---

## 设计目标

1. **高可靠**：单点故障（Worker 崩溃）不影响系统整体可用性。
2. **低延迟**：I/O 多路复用保证微秒级任务分发响应时间。
3. **确定性**：timerfd 提供精确到纳秒级的时间控制。
4. **零依赖**：纯 Linux 系统调用，无任何第三方库。
5. **可观测**：结构化 JSONL 日志，便于事后分析和问题定位。

---

## 系统架构

### 整体架构

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

### 组件职责

#### Manager（父进程）

- **唯一事件循环**：通过 epoll_wait() 统一管理所有 I/O 事件，O(1) 时间复杂度。
- **任务分发**：每 1 秒从任务池取任务，通过 socketpair 发送给空闲 Worker。
- **心跳看门狗**：每 2 秒向所有 Worker 发送 ping，3 个周期未收到 pong 则判定 Worker 崩溃。
- **故障自愈**：检测到 Worker 异常退出后立即 fork 新 Worker 替换，pending 任务重新入队。
- **统计报表**：每 5 秒输出系统运行状态。
- **输入处理**：监听 stdin，支持 `+`/`-` 动态调整 Worker 数量。

#### Worker（子进程）

- **纯执行单元**：不参与任何调度决策，只负责接收任务、执行、返回结果。
- **任务处理**：sleep(处理时间) 后返回 "done" 消息。
- **心跳响应**：收到 ping 后立即回复 pong。
- **退出协议**：收到 'X' 消息后优雅退出，避免僵尸进程。

---

## 核心机制

### I/O 多路复用（epoll LT 模式）

```
                        +------------------+
                        |   epoll_create   |
                        |  (红黑树 + 链表)  |
                        +--------+---------+
                                 |
           +---------------------+---------------------+
           |                     |                     |
+---------v---------++---------v---------++---------v---------+
| timerfd (1s)      || timerfd (2s)     || timerfd (5s)      |
| 分发定时器         || 心跳定时器        || 报表定时器         |
+---------+---------++---------+---------++---------+---------+
         |                     |                     |
         +---------------------+---------------------+
                               |
                    +----------v----------+
                    |     epoll_wait()    |
                    |  返回就绪事件列表    |
                    +----------+----------+
                               |
              +----------------+----------------+
              |                |                |
       +------v------+  +------v------+  +------v------+
       | read stdin  |  | read socket  |  | read socket  |
       |  (+ / - / q)|  |  (pong)      |  |  (done)      |
       +-------------+  +-------------+  +--------------+
```

- **LT（Level Triggered）模式**：就绪的 FD 只要未处理完，每次 epoll_wait 都会返回，无需重复注册。
- **红黑树管理**：所有 FD 以 O(log N) 复杂度插入/删除。
- **就绪链表**：就绪 FD 通过链表返回，遍历为 O(K)，K 为就绪数量。

### 定时器（timerfd）

Linux 提供的 timerfd API：

```c
int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
struct itimerspec spec;
spec.it_value.tv_sec = 1;    // 首次触发时间
spec.it_value.tv_nsec = 0;
spec.it_interval.tv_sec = 1; // 周期
spec.it_interval.tv_nsec = 0;
timerfd_settime(tfd, 0, &spec, NULL);
```

- **纳秒精度**：基于 CLOCK_MONOTONIC，不受系统时钟调整影响。
- **周期精确**：自动重载，无需重复设置。
- **统一接口**：定时器到期作为 epoll 事件，无需 signal 或额外线程。

### 进程间通信（socketpair）

```c
int sv[2];
socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
// Manager: close(sv[0]), read/write(sv[1])
// Worker:  close(sv[1]), read/write(sv[0])
```

- **SOCK_DGRAM**：数据报模式，消息边界明确，无需自定义协议。
- **全双工**：同一对 FD 既可读又可写。
- **文件描述符继承**：fork 后子进程自动继承，父进程可直接使用。
- **非阻塞 I/O**：两端均设为 O_NONBLOCK，配合 epoll 使用。

### 心跳与故障检测

```
Manager                          Worker
   |                                |
   | --- ping (every 2s) ---------> |
   | <-------- pong ----------------|
   |                                |
   | [Worker crashes]               |
   | --- ping --------------------->| (无响应)
   | [wait 3 cycles]                |
   | [detect: recv returns 0/err]    |
   | [kill remaining W]              |
   | [fork new Worker]               |
   | [re-enqueue pending tasks]      |
```

- **双通道检测**：既检测 write 返回错误，也检测 read 返回 0（对端关闭）。
- **主动杀死**：检测到崩溃后主动 SIGKILL 清理残留子进程。
- **任务抢救**：未完成的任务标记为 pending，重新入任务池。

### 优雅退出协议

```
用户按 Ctrl+C / 输入 q
        |
        V
Manager: 向所有 Worker 发送 'X'
        关闭所有 socketpair
        等待 epoll 接收剩余 done 消息
        打印最终统计
        退出 (exit 0)
```

- **有序关闭**：所有 pending 任务完成后再退出，保证无任务丢失。
- **信号处理**：SIGINT 信号触发相同退出路径。

---

## 数据结构

### Manager 端

```cpp
// Worker 描述符
struct WorkerInfo {
    pid_t pid;              // 子进程 PID
    int fd;                // socketpair FD（Manager 端）
    State state;           // IDLE / BUSY / DEAD
    int missed_heartbeats; // 连续未收到 pong 次数
    size_t tasks_done;      // 完成任务数
};

// 任务描述符
struct Task {
    uint64_t id;           // 全局唯一 ID
    char type;             // 'A' / 'B' / 'C'
    size_t retry;          // 当前重试次数
    uint64_t enqueue_time; // 入队时间戳
};
```

### Worker 端

```cpp
// 仅持有 socketpair 端 FD
int sock_fd;  // 由父进程通过 fork 继承
char buf[256];

while (1) {
    memset(buf, 0, sizeof(buf));
    ssize_t n = read(sock_fd, buf, sizeof(buf) - 1);
    if (n <= 0) break;  // 收到退出信号或连接关闭

    if (buf[0] == 'X') break;  // 优雅退出
    if (buf[0] == 'P') {
        write(sock_fd, "pong", 4);  // 心跳响应
    }
    // 处理任务...
    sleep(task_time);
    write(sock_fd, "done", 4);
}
```

---

## 关键设计决策

### 决策一：多进程 vs 多线程

| 维度 | 多进程 | 多线程 |
|------|--------|--------|
| 故障隔离 | 强（进程隔离） | 弱（共享地址空间） |
| 数据竞争 | 无（独立地址空间） | 需要锁保护 |
| 资源开销 | 较高（各自页表） | 较低（共享大部分） |
| 通信效率 | 中等（需 IPC） | 高（直接共享内存） |
| 调试难度 | 低（ps/pstree 清晰） | 高（线程竞态难复现） |

**结论**：座舱系统对可靠性要求极高，选择多进程架构。

### 决策二：epoll LT vs ET

| 维度 | LT（Level Triggered） | ET（Edge Triggered） |
|------|----------------------|---------------------|
| 编程复杂度 | 低（可重复处理） | 高（需一次性读完） |
| 适用场景 | 普通 I/O | 高速数据流（避免惊群） |
| 可靠性 | 高（不易漏事件） | 中（需仔细处理） |
| 本系统需求 | 适合 | 不必要 |

**结论**：选择 LT 模式，降低编程复杂度，提高可靠性。

### 决策三：timerfd vs SIGALRM

| 维度 | timerfd | SIGALRM |
|------|---------|---------|
| 与 epoll 集成 | 原生支持（作为 FD） | 需要 signalfd 或额外处理 |
| 精度 | 纳秒 | 秒（取决于设置） |
| 多定时器 | 轻松（每定时器一个 fd） | 复杂（需管理多个 timer） |
| 与 I/O 统一 | 完美（统一事件循环） | 需要分离 |

**结论**：timerfd 与 epoll 完美契合，无需引入 signal 处理复杂度。

---

## 性能分析

### 延迟分解

| 阶段 | 延迟 | 原因 |
|------|------|------|
| epoll_wait 返回 | < 100 us | 内核态直接返回就绪 FD |
| 任务分发（socketpair send） | < 50 us | 本地 UNIX domain socket，无网络栈 |
| Worker 处理 | 100~300 ms | sleep() 由内核调度 |
| done 消息返回 | < 50 us | 同上 |
| **端到端总延迟** | **< 1 ms** | 主要受内核调度影响 |

### 吞吐能力

- **最大并发 Worker**：10（可配置）
- **每秒最大任务数**：10 / 0.3s ≈ 33 任务/秒（纯 C 类任务）
- **瓶颈**：Worker 处理时间，而非 I/O 系统

### 内存占用

| 组件 | 内存占用 |
|------|---------|
| Manager | ~1 MB |
| 每个 Worker | ~5 MB（独立地址空间） |
| 10 Workers 总计 | ~51 MB |
| 任务队列 | ~1 MB / 1000 任务 |

---

## 安全性考虑

1. **资源限制**：Worker 被 fork 后立即失去父进程权限。
2. **FD 泄漏防护**：所有 FD 在析构时统一 close。
3. **僵尸进程防护**：Manager 始终 wait() 退出的子进程。
4. **OOM 保护**：通过限制 Worker 数量防止内存溢出。

---

## 扩展方向

- **HTTP/MQTT API**：远程注入任务，适合车联网场景。
- **共享内存**：大任务数据通过 mmap 传递，零拷贝。
- **多 Manager HA**：主备选举，保证 Manager 单点高可用。
- **Web 仪表盘**：实时可视化系统状态。
