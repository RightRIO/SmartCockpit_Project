# VoYah 系统设计文档

**文档状态**: Active
**版本**: 1.0
**最后更新**: 2026-05-18

---

## Executive Summary

VoYah 是一个面向智能座舱场景的高可靠、事件驱动型分布式任务调度系统，采用 epoll I/O 多路复用 + 多进程架构，在 Linux 嵌入式座舱环境中运行。系统支持运行时动态扩缩容、故障自愈、优雅退出等特性，具备以下核心能力：

- **单点故障容忍**：Worker 崩溃不影响系统整体可用性，故障自动恢复
- **微秒级响应**：基于 epoll + timerfd 的事件驱动架构，端到端延迟 < 1ms
- **零外部依赖**：纯 Linux 系统调用，部署简单，适合资源受限的嵌入式环境
- **可观测性**：结构化 JSONL 日志输出，便于运维监控和问题定位

---

## 1. 概述

### 1.1 背景

智能座舱系统对任务调度的可靠性和实时性有严格要求：

1. **功能安全需求**：座舱域涉及仪表盘、ADAS 等安全相关功能，任务调度系统必须保证高可用
2. **资源受限环境**：嵌入式座舱硬件资源有限，无法运行重量级中间件
3. **确定性要求**：任务执行时间需精确可控，避免不可预期的延迟
4. **长期运行**：座舱系统需要 7x24 小时稳定运行，对故障恢复能力要求高

### 1.2 系统定位

VoYah 定位为轻量级、高可靠的任务调度基础设施，为座舱应用提供统一的任务分发和执行能力。

---

## 2. Goals and Non-Goals

### 2.1 Goals（目标）

| 目标 | 描述 | 量化指标 |
|------|------|---------|
| **高可靠** | 单点故障不影响系统整体可用性 | Worker 崩溃自动恢复，0 任务丢失 |
| **低延迟** | 任务分发响应时间 | 端到端 < 1ms |
| **确定性** | 任务执行时间可控 | 纳秒级定时精度 |
| **零依赖** | 最小化外部依赖 | 仅使用 Linux 系统调用 |
| **可观测** | 运行时状态可监控 | JSONL 结构化日志 |

### 2.2 Non-Goals（不做的事）

| 范围 | 说明 |
|------|------|
| **分布式协调** | 不支持跨节点任务分发，本系统为单机架构 |
| **任务优先级** | 不实现复杂的优先级调度策略 |
| **持久化** | 不提供任务持久化能力（重启后任务丢失） |
| **资源隔离** | 不实现 CPU/内存资源的严格隔离 |

---

## 3. System Architecture

### 3.1 整体架构

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
      | +-pong  | | +-pong  | +-pong  |
      +---------+ +---------+ +---------+
```

### 3.2 组件职责

#### 3.2.1 Manager（父进程）

| 职责 | 描述 | 实现方式 |
|------|------|---------|
| 事件循环 | 统一管理所有 I/O 事件 | epoll_wait()，O(1) 时间复杂度 |
| 任务分发 | 每 1 秒从任务池取任务分发给空闲 Worker | socketpair 发送 |
| 心跳看门狗 | 每 2 秒发送 ping，检测 Worker 健康状态 | 连续 3 个周期无响应判定崩溃 |
| 故障自愈 | 崩溃后立即 fork 新 Worker 替换 | pending 任务重新入队 |
| 统计报表 | 每 5 秒输出系统运行状态 | JSONL 格式日志 |
| 输入处理 | 监听 stdin，支持 `+`/`-` 动态调整 Worker 数 | 标准输入事件 |

#### 3.2.2 Worker（子进程）

| 职责 | 描述 |
|------|------|
| 任务执行 | 接收任务后执行，返回结果 |
| 心跳响应 | 收到 ping 后立即回复 pong |
| 优雅退出 | 收到 'X' 消息后退出 |

---

## 4. Core Mechanisms

### 4.1 I/O 多路复用（epoll LT 模式）

```
                        +------------------+
                        |   epoll_create   |
                        |  (红黑树 + 链表)  |
                        +--------+---------+
                                 |
           +---------------------+---------------------+
           |                     |                     |
+---------v---------+ +---------v---------+ +---------v---------+
| timerfd (1s)      | | timerfd (2s)     | | timerfd (5s)      |
| 分发定时器         | | 心跳定时器        | | 报表定时器         |
+---------+---------+ +---------+---------+ +---------+---------+
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

| 特性 | 说明 |
|------|------|
| LT（Level Triggered） | 就绪 FD 未处理完时，每次 epoll_wait 都会返回 |
| 红黑树管理 | FD 以 O(log N) 复杂度插入/删除 |
| 就绪链表 | 就绪 FD 通过链表返回，遍历为 O(K) |

### 4.2 定时器（timerfd）

```c
int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
struct itimerspec spec;
spec.it_value.tv_sec = 1;    // 首次触发时间
spec.it_value.tv_nsec = 0;
spec.it_interval.tv_sec = 1; // 周期
spec.it_interval.tv_nsec = 0;
timerfd_settime(tfd, 0, &spec, NULL);
```

| 特性 | 说明 |
|------|------|
| 纳秒精度 | 基于 CLOCK_MONOTONIC，不受系统时钟调整影响 |
| 周期精确 | 自动重载，无需重复设置 |
| 统一接口 | 定时器到期作为 epoll 事件，无需 signal 或额外线程 |

### 4.3 进程间通信（socketpair）

```c
int sv[2];
socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
// Manager: close(sv[0]), read/write(sv[1])
// Worker:  close(sv[1]), read/write(sv[0])
```

| 特性 | 说明 |
|------|------|
| SOCK_DGRAM | 数据报模式，消息边界明确，无需自定义协议 |
| 全双工 | 同一对 FD 既可读又可写 |
| FD 继承 | fork 后子进程自动继承，父进程可直接使用 |
| 非阻塞 I/O | 两端均设为 O_NONBLOCK，配合 epoll 使用 |

### 4.4 心跳与故障检测

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
   | [re-enqueue pending tasks]     |
```

| 检测手段 | 说明 |
|---------|------|
| 双通道检测 | 检测 write 返回错误 + read 返回 0（对端关闭） |
| 主动清理 | 崩溃后主动 SIGKILL 清理残留子进程 |
| 任务抢救 | 未完成任务标记为 pending，重新入任务池 |

### 4.5 优雅退出协议

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

| 特性 | 说明 |
|------|------|
| 有序关闭 | 所有 pending 任务完成后再退出，保证无任务丢失 |
| 信号处理 | SIGINT 信号触发相同退出路径 |

---

## 5. Data Models

### 5.1 Manager 端数据结构

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

### 5.2 Worker 端数据结构

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

### 5.3 消息协议

| 消息 | 方向 | 内容 | 说明 |
|------|------|------|------|
| task | Manager -> Worker | 类型标识 | 分发任务 |
| done | Worker -> Manager | "done" | 任务完成 |
| ping | Manager -> Worker | 'P' | 心跳探测 |
| pong | Worker -> Manager | "pong" | 心跳响应 |
| quit | Manager -> Worker | 'X' | 优雅退出 |

---

## 6. Design Decisions

### 6.1 多进程 vs 多线程

| 维度 | 多进程 | 多线程 | 本系统决策 |
|------|--------|--------|-----------|
| 故障隔离 | 强（进程隔离） | 弱（共享地址空间） | 多进程 |
| 数据竞争 | 无（独立地址空间） | 需要锁保护 | 多进程 |
| 资源开销 | 较高（各自页表） | 较低（共享大部分） | 可接受 |
| 通信效率 | 中等（需 IPC） | 高（直接共享内存） | socketpair 足够 |
| 调试难度 | 低（ps/pstree 清晰） | 高（线程竞态难复现） | 多进程 |

**结论**：座舱系统对可靠性要求极高，进程隔离是必要保障，选择多进程架构。

### 6.2 epoll LT vs ET

| 维度 | LT（Level Triggered） | ET（Edge Triggered） | 本系统决策 |
|------|----------------------|---------------------|-----------|
| 编程复杂度 | 低（可重复处理） | 高（需一次性读完） | LT |
| 适用场景 | 普通 I/O | 高速数据流（避免惊群） | LT |
| 可靠性 | 高（不易漏事件） | 中（需仔细处理） | LT |
| 本系统需求 | 适合 | 不必要 | LT |

**结论**：选择 LT 模式，降低编程复杂度，提高可靠性。

### 6.3 timerfd vs SIGALRM

| 维度 | timerfd | SIGALRM | 本系统决策 |
|------|---------|---------|-----------|
| 与 epoll 集成 | 原生支持（作为 FD） | 需要 signalfd 或额外处理 | timerfd |
| 精度 | 纳秒 | 秒（取决于设置） | timerfd |
| 多定时器 | 轻松（每定时器一个 fd） | 复杂（需管理多个 timer） | timerfd |
| 与 I/O 统一 | 完美（统一事件循环） | 需要分离 | timerfd |

**结论**：timerfd 与 epoll 完美契合，无需引入 signal 处理复杂度。

---

## 7. Capacity and Performance

### 7.1 延迟分解

| 阶段 | 延迟 | 原因 |
|------|------|------|
| epoll_wait 返回 | < 100 us | 内核态直接返回就绪 FD |
| 任务分发（socketpair send） | < 50 us | 本地 UNIX domain socket，无网络栈 |
| Worker 处理 | 100~300 ms | sleep() 由内核调度 |
| done 消息返回 | < 50 us | 同上 |
| **端到端总延迟** | **< 1 ms** | 主要受内核调度影响 |

### 7.2 吞吐能力

| 指标 | 数值 | 说明 |
|------|------|------|
| 最大并发 Worker | 10 | 可配置 |
| 每秒最大任务数 | ~33 任务/秒 | 基于 0.3s 平均处理时间 |
| 瓶颈 | Worker 处理时间 | 而非 I/O 系统 |

### 7.3 资源占用

| 组件 | 内存占用 |
|------|---------|
| Manager | ~1 MB |
| 每个 Worker | ~5 MB（独立地址空间） |
| 10 Workers 总计 | ~51 MB |
| 任务队列 | ~1 MB / 1000 任务 |

---

## 8. Reliability and Safety

### 8.1 故障处理

| 故障场景 | 检测方式 | 处理策略 |
|---------|---------|---------|
| Worker 崩溃 | 心跳超时（3 个周期） | fork 新 Worker，pending 任务重新入队 |
| Worker 无响应 | 心跳无 pong | 同上 |
| Manager 异常退出 | SIGINT/SIGTERM | 向所有 Worker 发送 'X'，优雅退出 |

### 8.2 资源保护

| 保护机制 | 实现方式 |
|---------|---------|
| FD 泄漏防护 | 所有 FD 在析构时统一 close |
| 僵尸进程防护 | Manager 始终 wait() 退出的子进程 |
| OOM 保护 | 通过限制 Worker 数量防止内存溢出 |
| 权限隔离 | Worker 被 fork 后立即失去父进程权限 |

---

## 9. Operations

### 9.1 部署说明

| 项目 | 说明 |
|------|------|
| 运行环境 | Linux，x86_64 或 ARM 架构 |
| 编译方式 | CMake，输出单一可执行文件 |
| 启动命令 | `./voyah` |
| 运行时依赖 | 无（静态链接） |

### 9.2 运行时配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| Worker 数量 | 3 | 可通过 `+`/`-` 动态调整 |
| 最大 Worker | 10 | 配置项 |
| 心跳间隔 | 2s | timerfd 配置 |
| 任务分发间隔 | 1s | timerfd 配置 |
| 报表输出间隔 | 5s | timerfd 配置 |

### 9.3 运维命令

| 命令 | 操作 |
|------|------|
| `+` | 增加一个 Worker |
| `-` | 减少一个 Worker |
| `q` | 优雅退出系统 |

### 9.4 监控指标

系统每 5 秒输出 JSONL 格式的运行状态日志：

```json
{"ts": 1234567890, "type": "stats", "workers": 3, "idle": 2, "busy": 1, "tasks_done": 42, "pending": 5}
```

| 字段 | 说明 |
|------|------|
| ts | 时间戳 |
| type | 日志类型 |
| workers | 当前 Worker 总数 |
| idle | 空闲 Worker 数 |
| busy | 忙碌 Worker 数 |
| tasks_done | 累计完成任务数 |
| pending | 待处理任务数 |

---

## 10. Open Questions

| 问题 | 状态 | 备注 |
|------|------|------|
| Manager 单点故障 | 待解决 | 目前 Manager 崩溃会导致系统退出 |
| 任务优先级 | 暂不支持 | 未来可扩展 |
| 任务持久化 | 暂不支持 | 重启后任务丢失 |

---

## 11. Future Work

| 功能 | 描述 | 优先级 |
|------|------|--------|
| HTTP/MQTT API | 远程注入任务，适合车联网场景 | P1 |
| 共享内存 | 大任务数据通过 mmap 传递，零拷贝 | P2 |
| 多 Manager HA | 主备选举，保证 Manager 高可用 | P2 |
| Web 仪表盘 | 实时可视化系统状态 | P3 |

---

## Appendix

### A. 术语表

| 术语 | 说明 |
|------|------|
| Manager | 父进程，负责任务调度和 Worker 管理 |
| Worker | 子进程，负责执行具体任务 |
| epoll | Linux I/O 多路复用机制 |
| timerfd | Linux 定时器文件描述符 |
| socketpair | Unix 域套接字，用于进程间通信 |
| LT | Level Triggered，水平触发模式 |
| ET | Edge Triggered，边沿触发模式 |

### B. 参考资料

- Linux man pages: epoll, timerfd_create, socketpair
- 《Unix 网络编程》- W. Richard Stevens
- 《Linux 高性能服务器编程》
