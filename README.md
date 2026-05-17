# VoYah 智能座舱作业 — 分布式任务调度监控系统

## 项目结构

```
VoYah_project/
├── Makefile           # 构建脚本（make / make test / make clean）
├── scheduler.cpp      # 完整源代码（单文件）
├── scheduler          # 编译产物（由 make 生成）
├── DESIGN.md          # 系统设计文档（架构图 + epoll 选型理由）
├── README.md          # 本文件
├── test/
│   ├── test_boundary.sh   # 边界值测试（N=3, N=10, N=2/11）
│   └── test_stress.sh     # 压力测试（所有 Worker 同时故障）
└── include/          # 预留：后续可拆分出头文件
```

## 快速开始

```bash
# 编译
make

# 运行（启动 N 个 Worker，3 ≤ N ≤ 10）
./bin/scheduler 5

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

## 测试说明

### 边界值测试 (`test_boundary.sh`)

| 测试用例 | 预期行为 |
|---------|---------|
| `N=3` | 正常启动，Worker 创建、任务分发、统计报告均正常 |
| `N=10` | 正常启动，10 个 Worker 均正常运作 |
| `N=2` | 拒绝启动，输出参数校验错误 |
| `N=11` | 拒绝启动，输出参数校验错误 |
| 无参数 | 显示 Usage 用法提示 |

### 压力测试 (`test_stress.sh`)

模拟所有 Worker 被 `kill -9` 强制终止的场景，验证：

1. Manager 在所有 Worker 崩溃后仍能独立存活（故障自愈）
2. 无僵尸进程残留
3. 优雅退出流程完整执行

## 任务类型

| 类型 | 模拟处理时间 | 说明 |
|------|------------|------|
| A | 100 ms | 轻量任务 |
| B | 200 ms | 中量任务 |
| C | 300 ms | 重量任务 |

## 编译依赖

- Linux（需要 `epoll`、`timerfd`、`socketpair`）
- GCC 7+ 或 Clang（支持 C++17）
- GNU Make
