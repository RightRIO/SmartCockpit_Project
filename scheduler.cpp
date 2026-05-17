#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <iostream>
#include <vector>
#include <memory>
#include <cstring>
#include <cstdarg>
#include <unordered_map>
#include <deque>
#include <algorithm>
#include <numeric>
#include <climits>
#include <ctime>
#include <cstdlib>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <stdint.h>
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>

// ---------- 前置声明 ----------
class EventLoop;

// ---------- 常量 ----------
const char TASK_A = 'A';
const char TASK_B = 'B';
const char TASK_C = 'C';
const char TASK_EXIT = 'X';
const char TASK_PING = 'P';
const int MAX_RETRIES = 2;
const int TIMEOUT_SECS = 5;
const int HEARTBEAT_INTERVAL_SECS = 2;
const int HEARTBEAT_TIMEOUT_SECS = 6;
const int TASK_SLEEP_A = 100;
const int TASK_SLEEP_B = 200;
const int TASK_SLEEP_C = 300;

// ---------- 任务配置表 ----------
struct TaskConfig {
    char type;
    int sleep_ms;
    const char* name;
};

const TaskConfig kTaskConfigs[] = {
    {TASK_A, TASK_SLEEP_A, "LightTask"},
    {TASK_B, TASK_SLEEP_B, "MediumTask"},
    {TASK_C, TASK_SLEEP_C, "HeavyTask"},
};

inline int get_task_sleep_ms(char type) {
    if (type == TASK_A) return TASK_SLEEP_A;
    if (type == TASK_B) return TASK_SLEEP_B;
    if (type == TASK_C) return TASK_SLEEP_C;
    return 0;
}

// ---------- 消息定义 ----------
#pragma pack(1)
struct TaskMsg {
    char type;
    uint32_t seq;
};
#pragma pack()

// ---------- 任务追踪记录 ----------
struct TaskRecord {
    char type;
    uint32_t seq;
    int64_t dispatch_time_ms;  // 毫秒时间戳
    pid_t target_pid;
    int retry_count = 0;
};

// ---------- 全局统计 ----------
struct GlobalStats {
    int64_t start_time_ms = 0;
    int total_dispatched = 0;
    int total_completed = 0;
    int total_timeout = 0;
    int total_retry = 0;
    int total_failed = 0;

    int64_t latency_sum_ms = 0;
    int64_t latency_min_ms = INT64_MAX;
    int64_t latency_max_ms = 0;

    void record_latency(int64_t ms) {
        if (ms > latency_max_ms) latency_max_ms = ms;
        if (ms < latency_min_ms) latency_min_ms = ms;
        latency_sum_ms += ms;
    }

    double avg_latency_ms() const {
        return total_completed > 0 ? (double)latency_sum_ms / total_completed : 0;
    }
};

// ---------- 通信通道 ----------
class IpcChannel {
public:
    explicit IpcChannel(int fd) : fd_(fd) {}
    ~IpcChannel() {
        if (fd_ != -1) close(fd_);
    }

    IpcChannel(const IpcChannel&) = delete;
    IpcChannel& operator=(const IpcChannel&) = delete;
    IpcChannel(IpcChannel&& other) noexcept : fd_(other.fd_) {
        other.fd_ = -1;
    }

    int get_fd() const { return fd_; }

    bool send_msg(char type, uint32_t seq) {
        TaskMsg msg{type, seq};
        return send(fd_, &msg, sizeof(msg), MSG_NOSIGNAL) == sizeof(msg);
    }

    bool recv_msg(char& type, uint32_t& seq) {
        TaskMsg msg;
        ssize_t n = recv(fd_, &msg, sizeof(msg), 0);
        if (n != sizeof(msg)) return false;
        type = msg.type;
        seq = msg.seq;
        return true;
    }

private:
    int fd_;
};

// ---------- Worker 数据结构 ----------
struct Worker {
    pid_t pid;
    std::unique_ptr<IpcChannel> channel;
    int task_count = 0;
    int type_count[3] = {0, 0, 0};
    bool alive = true;
    int pending_count = 0;
    int64_t start_time_ms = 0;
    int64_t last_heartbeat_ms = 0;
};

// ---------- Worker 管理类 ----------
class WorkerManager {
public:
    explicit WorkerManager(EventLoop* loop);
    ~WorkerManager();

    void add_worker();
    void remove_worker();
    void replace_worker(size_t idx);
    void remove_worker_by_fd(int fd);

    void shutdown_and_wait();

    void dispatch_tasks();
    void dispatch_retries();
    void handle_message(int fd);
    void check_timeouts();
    void check_heartbeat();
    void send_ping_to_all();

    void print_statistics();
    void print_worker_info();
    void print_pending_tasks();

    void write_log_event(const char* event, const char* fmt, ...);

    size_t size() const { return workers_.size(); }

    int64_t now_ms() const;

    GlobalStats& stats() { return stats_; }
    std::vector<Worker>& workers() { return workers_; }

private:
    std::vector<Worker> workers_;
    EventLoop* loop_;
    uint32_t next_seq_ = 1;

    // 任务追踪
    std::unordered_map<uint32_t, TaskRecord> task_tracker_;

    // 待重试任务队列 (type, seq)
    std::deque<std::pair<char, uint32_t>> retry_queue_;

    GlobalStats stats_;

    FILE* log_file_ = nullptr;

    static void worker_main(int fd);

    // 内部辅助
    void open_log_file();
    void close_log_file();
    Worker* find_worker_by_fd(int fd);
    Worker* find_worker_by_pid(pid_t pid);
};

// ---------- 事件循环类 ----------
class EventLoop {
public:
    EventLoop();
    ~EventLoop();

    void add_fd(int fd, uint32_t events);
    void del_fd(int fd);
    void set_manager(WorkerManager* mgr) { manager_ = mgr; }

    void run();

    int get_timer_1s() const { return timerfd_1s_; }
    int get_timer_2s() const { return timerfd_2s_; }
    int get_timer_5s() const { return timerfd_5s_; }

private:
    int epoll_fd_ = -1;
    int timerfd_1s_ = -1;
    int timerfd_2s_ = -1;
    int timerfd_5s_ = -1;
    WorkerManager* manager_ = nullptr;

    void init_timerfd();
    void process_stdin();
};

// ---------- 全局变量 ----------
WorkerManager* g_worker_manager = nullptr;
volatile sig_atomic_t g_running = 1;

void signal_handler(int sig) {
    if (!g_worker_manager) return;
    if (sig == SIGUSR1)
        g_worker_manager->add_worker();
    else if (sig == SIGUSR2)
        g_worker_manager->remove_worker();
}

void shutdown_handler(int) {
    g_running = 0;
}

// ---------- JSONL 日志辅助 ----------
void WorkerManager::write_log_event(const char* event, const char* fmt, ...) {
    if (!log_file_) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    struct timeval tv;
    gettimeofday(&tv, nullptr);
    int64_t now_ms = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;

    fprintf(log_file_, "{\"event\":\"%s\",\"%s\",\"time_ms\":%lld}\n",
            event, buf, (long long)now_ms);
    fflush(log_file_);
}

// ---------- WorkerManager 实现 ----------

WorkerManager::WorkerManager(EventLoop* loop) : loop_(loop) {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    stats_.start_time_ms = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
    open_log_file();
}

WorkerManager::~WorkerManager() {
    close_log_file();
}

void WorkerManager::open_log_file() {
    char fname[128];
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    struct tm* tm_info = localtime(&tv.tv_sec);
    snprintf(fname, sizeof(fname),
             "scheduler_%04d%02d%02d_%02d%02d%02d.jsonl",
             tm_info->tm_year + 1900, tm_info->tm_mon + 1, tm_info->tm_mday,
             tm_info->tm_hour, tm_info->tm_min, tm_info->tm_sec);
    log_file_ = fopen(fname, "w");
    if (log_file_) {
        std::cout << "[LOG] 结构化日志文件已创建: " << fname << "\n";
    } else {
        std::cerr << "[WARN] 无法创建日志文件: " << fname << "\n";
    }
}

void WorkerManager::close_log_file() {
    if (log_file_) {
        fclose(log_file_);
        log_file_ = nullptr;
    }
}

int64_t WorkerManager::now_ms() const {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

Worker* WorkerManager::find_worker_by_fd(int fd) {
    for (auto& w : workers_) {
        if (w.channel && w.channel->get_fd() == fd)
            return &w;
    }
    return nullptr;
}

Worker* WorkerManager::find_worker_by_pid(pid_t pid) {
    for (auto& w : workers_) {
        if (w.pid == pid)
            return &w;
    }
    return nullptr;
}

char get_random_task() {
    int r = rand() % 3;
    return (r == 0) ? TASK_A : (r == 1) ? TASK_B : TASK_C;
}

// Worker 主函数（子进程执行）
void WorkerManager::worker_main(int fd) {
    IpcChannel channel(fd);
    int task_count = 0;
    int type_cnt[3] = {0};

    while (true) {
        char type;
        uint32_t seq;
        if (!channel.recv_msg(type, seq)) break;

        if (type == TASK_EXIT) {
            printf("[W%d] EXIT: total=%d A=%d B=%d C=%d\n",
                   (int)getpid(), task_count, type_cnt[0], type_cnt[1], type_cnt[2]);
            fflush(stdout);
            break;
        }

        if (type == TASK_PING) {
            channel.send_msg(TASK_PING, 0);
            continue;
        }

        int sleep_ms = get_task_sleep_ms(type);
        if (sleep_ms > 0) {
            usleep(sleep_ms * 1000);
        }

        if (!channel.send_msg(type, seq)) break;

        task_count++;
        if (type == TASK_A)      type_cnt[0]++;
        else if (type == TASK_B) type_cnt[1]++;
        else if (type == TASK_C) type_cnt[2]++;
    }
}

void WorkerManager::add_worker() {
    if (workers_.size() >= 10) {
        std::cout << "[WARN] 已达最大 Worker 数 10，拒绝新增\n";
        return;
    }

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) < 0) {
        perror("socketpair");
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        worker_main(sv[1]);
        close(sv[1]);
        exit(0);
    } else if (pid > 0) {
        close(sv[1]);
        Worker w;
        w.pid = pid;
        w.channel = std::make_unique<IpcChannel>(sv[0]);
        w.start_time_ms = now_ms();
        w.last_heartbeat_ms = now_ms();
        loop_->add_fd(w.channel->get_fd(), EPOLLIN);
        workers_.push_back(std::move(w));

        write_log_event("worker_add",
                        "\"pid\":%d,\"worker_count\":%zu",
                        pid, workers_.size());
        std::cout << "[INFO] Worker 已创建: PID=" << pid
                  << " 当前数量: " << workers_.size() << "\n";
    } else {
        perror("fork");
    }
}

void WorkerManager::remove_worker() {
    if (workers_.empty()) {
        std::cout << "[WARN] 没有 Worker 可删除\n";
        return;
    }

    Worker& last = workers_.back();
    last.channel->send_msg(TASK_EXIT, 0);
    int status;
    waitpid(last.pid, &status, 0);
    loop_->del_fd(last.channel->get_fd());

    pid_t removed_pid = last.pid;
    workers_.pop_back();

    write_log_event("worker_remove",
                    "\"pid\":%d,\"worker_count\":%zu",
                    removed_pid, workers_.size());
    std::cout << "[INFO] Worker 已移除: PID=" << removed_pid
              << " 当前数量: " << workers_.size() << "\n";
}

void WorkerManager::replace_worker(size_t idx) {
    if (idx >= workers_.size()) return;
    Worker& w = workers_[idx];
    pid_t old_pid = w.pid;

    // 收集该 Worker 未完成的任务
    int rescued = 0;
    for (auto it = task_tracker_.begin(); it != task_tracker_.end(); ) {
        if (it->second.target_pid == old_pid) {
            char t = it->second.type;
            uint32_t s = it->second.seq;
            retry_queue_.push_back({t, s});
            it = task_tracker_.erase(it);
            ++rescued;
        } else {
            ++it;
        }
    }

    // 关闭旧 fd，解除 epoll 监听
    loop_->del_fd(w.channel->get_fd());
    w.channel.reset();
    int status;
    waitpid(old_pid, &status, WNOHANG);

    write_log_event("worker_replaced",
                    "\"old_pid\":%d,\"new_pid\":-1,\"rescued_tasks\":%d",
                    old_pid, rescued);

    // fork 新 Worker
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) < 0) {
        perror("socketpair");
        return;
    }

    pid_t new_pid = fork();
    if (new_pid == 0) {
        close(sv[0]);
        worker_main(sv[1]);
        close(sv[1]);
        exit(0);
    } else if (new_pid > 0) {
        close(sv[1]);
        w.pid = new_pid;
        w.channel = std::make_unique<IpcChannel>(sv[0]);
        w.start_time_ms = now_ms();
        w.last_heartbeat_ms = now_ms();
        w.task_count = 0;
        w.type_count[0] = w.type_count[1] = w.type_count[2] = 0;
        w.pending_count = 0;
        w.alive = true;
        loop_->add_fd(w.channel->get_fd(), EPOLLIN);

        write_log_event("worker_replaced",
                        "\"old_pid\":%d,\"new_pid\":%d,\"rescued_tasks\":%d",
                        old_pid, new_pid, rescued);
        std::cout << "[RECOVERY] Worker 已自动替换: " << old_pid
                  << " -> " << new_pid
                  << "，已补偿 " << rescued << " 个任务\n";
    }
}

void WorkerManager::remove_worker_by_fd(int fd) {
    for (size_t i = 0; i < workers_.size(); ++i) {
        if (workers_[i].channel && workers_[i].channel->get_fd() == fd) {
            std::cout << "[WARN] Worker (PID " << workers_[i].pid
                      << ") 异常，触发自动替换...\n";

            write_log_event("worker_crash",
                            "\"pid\":%d,\"pending_count\":%d",
                            workers_[i].pid, workers_[i].pending_count);

            replace_worker(i);
            return;
        }
    }
}

void WorkerManager::shutdown_and_wait() {
    std::cout << "\n[SHUTDOWN] 正在向所有 Worker 发送退出信号（优雅退出）...\n";

    for (auto& w : workers_) {
        if (w.alive && w.channel) {
            w.channel->send_msg(TASK_EXIT, 0);
        }
    }

    if (workers_.empty()) {
        std::cout << "[SHUTDOWN] 所有 Worker 已提前退出，无需额外清理。\n";
        return;
    }

    for (auto& w : workers_) {
        int status;
        waitpid(w.pid, &status, 0);
        std::cout << "[SHUTDOWN] Worker (PID " << w.pid << ") 已回收，退出状态: "
                  << WEXITSTATUS(status) << "\n";
    }
    workers_.clear();
    std::cout << "[SHUTDOWN] 所有 Worker 已优雅退出，无僵尸进程残留。\n";
}

void WorkerManager::dispatch_tasks() {
    if (workers_.empty()) return;

    // 清理失效 Worker（已在上一轮被 replace_worker 处理）
    for (auto it = workers_.begin(); it != workers_.end(); ) {
        if (!it->alive || !it->channel) {
            if (it->channel) loop_->del_fd(it->channel->get_fd());
            it = workers_.erase(it);
        } else {
            ++it;
        }
    }
    if (workers_.empty()) return;

    // 每次生成与存活 Worker 数量相同的新任务
    // 使用最少待办数（least-pending）负载均衡
    std::vector<size_t> order(workers_.size());
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(),
                     [&](size_t a, size_t b) {
                         return workers_[a].pending_count < workers_[b].pending_count;
                     });

    for (size_t idx : order) {
        Worker& w = workers_[idx];
        if (!w.alive || !w.channel) continue;

        char task = get_random_task();
        uint32_t seq = next_seq_++;

        if (!w.channel->send_msg(task, seq)) {
            std::cerr << "[ERROR] 任务派发到 Worker " << w.pid << " 失败，触发替换\n";
            replace_worker(idx);
            continue;
        }

        // 记录到 tracker
        TaskRecord rec;
        rec.type = task;
        rec.seq = seq;
        rec.dispatch_time_ms = now_ms();
        rec.target_pid = w.pid;
        rec.retry_count = 0;
        task_tracker_[seq] = rec;

        w.pending_count++;
        stats_.total_dispatched++;

        write_log_event("dispatch",
                        "\"seq\":%u,\"type\":\"%c\",\"target_pid\":%d,\"pending\":%d",
                        seq, task, w.pid, w.pending_count);
    }
}

void WorkerManager::dispatch_retries() {
    while (!retry_queue_.empty()) {
        // 找一个 pending_count 最少的 Worker
        Worker* target = nullptr;
        int min_pending = INT_MAX;
        for (auto& w : workers_) {
            if (w.alive && w.channel && w.pending_count < min_pending) {
                min_pending = w.pending_count;
                target = &w;
            }
        }
        if (!target) break;

        auto [type, old_seq] = retry_queue_.front();
        retry_queue_.pop_front();

        uint32_t new_seq = next_seq_++;
        if (!target->channel->send_msg(type, new_seq)) {
            remove_worker_by_fd(target->channel->get_fd());
            retry_queue_.push_back({type, old_seq});
            continue;
        }

        TaskRecord rec;
        rec.type = type;
        rec.seq = new_seq;
        rec.dispatch_time_ms = now_ms();
        rec.target_pid = target->pid;
        rec.retry_count = 1;
        task_tracker_[new_seq] = rec;

        target->pending_count++;
        stats_.total_dispatched++;
        stats_.total_retry++;

        write_log_event("retry",
                        "\"old_seq\":%u,\"new_seq\":%u,\"type\":\"%c\",\"target_pid\":%d",
                        old_seq, new_seq, type, target->pid);
    }
}

void WorkerManager::handle_message(int fd) {
    Worker* target = find_worker_by_fd(fd);
    if (!target) return;

    char type;
    uint32_t seq;
    if (!target->channel->recv_msg(type, seq)) {
        std::cerr << "[ERROR] 与 Worker (PID " << target->pid
                  << ") 通信失败，触发自动替换\n";
        remove_worker_by_fd(fd);
        return;
    }

    // PING 响应
    if (type == TASK_PING) {
        target->last_heartbeat_ms = now_ms();
        write_log_event("pong", "\"from_pid\":%d", target->pid);
        return;
    }

    // 找到对应的 tracker 记录
    auto it = task_tracker_.find(seq);
    if (it == task_tracker_.end()) {
        // seq 不在 tracker 中（可能是重试后的新 seq，已被处理）
        return;
    }

    int64_t latency = now_ms() - it->second.dispatch_time_ms;
    stats_.total_completed++;
    stats_.record_latency(latency);

    target->task_count++;
    if (type == TASK_A)      target->type_count[0]++;
    else if (type == TASK_B) target->type_count[1]++;
    else if (type == TASK_C) target->type_count[2]++;

    target->pending_count = std::max(0, target->pending_count - 1);
    target->last_heartbeat_ms = now_ms();

    task_tracker_.erase(it);

    write_log_event("complete",
                    "\"seq\":%u,\"type\":\"%c\",\"target_pid\":%d,"
                    "\"latency_ms\":%lld,\"time_ms\":%lld",
                    seq, type, target->pid,
                    (long long)latency, (long long)now_ms());
}

void WorkerManager::check_timeouts() {
    int64_t now = now_ms();
    std::vector<uint32_t> to_remove;

    for (auto& [seq, rec] : task_tracker_) {
        int64_t elapsed = now - rec.dispatch_time_ms;
        if (elapsed > TIMEOUT_SECS * 1000) {
            if (rec.retry_count < MAX_RETRIES) {
                // 入重试队列
                retry_queue_.push_back({rec.type, seq});
                stats_.total_timeout++;
                write_log_event("timeout",
                                "\"seq\":%u,\"type\":\"%c\",\"target_pid\":%d,"
                                "\"retry\":%d,\"elapsed_ms\":%lld",
                                seq, rec.type, rec.target_pid,
                                rec.retry_count + 1, (long long)elapsed);
            } else {
                // 超过最大重试次数，标记失败
                stats_.total_failed++;
                write_log_event("failed",
                                "\"seq\":%u,\"type\":\"%c\",\"reason\":\"max_retries\"",
                                seq, rec.type);
            }
            to_remove.push_back(seq);
        }
    }

    for (uint32_t s : to_remove) {
        task_tracker_.erase(s);
    }

    if (!retry_queue_.empty()) {
        dispatch_retries();
    }
}

void WorkerManager::send_ping_to_all() {
    for (auto& w : workers_) {
        if (!w.alive || !w.channel) continue;
        if (!w.channel->send_msg(TASK_PING, 0)) {
            remove_worker_by_fd(w.channel->get_fd());
        }
        write_log_event("ping", "\"target_pid\":%d", w.pid);
    }
}

void WorkerManager::check_heartbeat() {
    int64_t now = now_ms();
    std::vector<size_t> dead_indices;

    for (size_t i = 0; i < workers_.size(); ++i) {
        auto& w = workers_[i];
        if (!w.alive || !w.channel) continue;
        int64_t elapsed = now - w.last_heartbeat_ms;
        if (elapsed > HEARTBEAT_TIMEOUT_SECS * 1000) {
            std::cout << "[WATCHDOG] Worker PID=" << w.pid
                      << " 超过 " << HEARTBEAT_TIMEOUT_SECS
                      << " 秒无响应，触发自动替换\n";
            dead_indices.push_back(i);
        }
    }

    // 倒序替换（避免索引偏移）
    for (auto it = dead_indices.rbegin(); it != dead_indices.rend(); ++it) {
        replace_worker(*it);
    }
}

// ---------- 增强统计报告 ----------
void WorkerManager::print_statistics() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    int64_t now_ms_val = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
    int elapsed_s = (int)((now_ms_val - stats_.start_time_ms) / 1000);
    if (elapsed_s <= 0) elapsed_s = 1;

    double throughput = (double)stats_.total_completed / elapsed_s;

    std::cout << "\n========== 系统统计报告 (每5秒) ==========\n";
    std::cout << "系统运行时间: " << elapsed_s << "s  |  "
              << "总派发: " << stats_.total_dispatched
              << "  |  吞吐量: " << throughput << " tasks/s\n";
    std::cout << "已完成: " << stats_.total_completed
              << "  |  超时: " << stats_.total_timeout
              << "  |  重试: " << stats_.total_retry
              << "  |  失败: " << stats_.total_failed << "\n";
    std::cout << "-------------------------------------------\n";

    std::cout << "Worker   存活    存活时间    完成任务    A      B      C    待处理\n";
    for (size_t i = 0; i < workers_.size(); ++i) {
        auto& w = workers_[i];
        int w_elapsed = (int)((now_ms_val - w.start_time_ms) / 1000);
        const char* alive_str = w.alive ? "YES" : "NO";
        std::cout << "  W" << (i + 1)
                  << "    [" << alive_str << "]"
                  << "    " << w_elapsed << "s"
                  << "        " << w.task_count
                  << "       " << w.type_count[0]
                  << "     " << w.type_count[1]
                  << "     " << w.type_count[2]
                  << "      " << w.pending_count << "\n";
    }
    std::cout << "-------------------------------------------\n";

    if (stats_.total_completed > 0) {
        std::cout << "任务延迟: avg=" << stats_.avg_latency_ms() << "ms"
                  << "  min=" << stats_.latency_min_ms << "ms"
                  << "  max=" << stats_.latency_max_ms << "ms\n";
    } else {
        std::cout << "任务延迟: 暂无数据\n";
    }
    std::cout << "===========================================\n";
}

void WorkerManager::print_worker_info() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    int64_t now_ms_val = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;

    std::cout << "\n========== Worker 详细信息 ==========\n";
    std::cout << "PID        存活   存活时间   完成任务   A    B    C   待处理   最后心跳\n";
    for (size_t i = 0; i < workers_.size(); ++i) {
        auto& w = workers_[i];
        int w_elapsed = (int)((now_ms_val - w.start_time_ms) / 1000);
        int hb_elapsed = (int)((now_ms_val - w.last_heartbeat_ms) / 1000);
        std::cout << " " << w.pid
                  << "     [" << (w.alive ? "YES" : "NO") << "]"
                  << "     " << w_elapsed << "s"
                  << "       " << w.task_count
                  << "     " << w.type_count[0]
                  << "   " << w.type_count[1]
                  << "   " << w.type_count[2]
                  << "      " << w.pending_count
                  << "        " << hb_elapsed << "s ago\n";
    }
    std::cout << "=====================================\n";
}

void WorkerManager::print_pending_tasks() {
    std::cout << "\n========== 待追踪任务 (共 "
              << task_tracker_.size() << " 个) ==========\n";
    if (task_tracker_.empty()) {
        std::cout << "  （无待处理任务）\n";
    } else {
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        int64_t now_ms_val = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
        for (auto& [seq, rec] : task_tracker_) {
            int64_t elapsed = now_ms_val - rec.dispatch_time_ms;
            std::cout << "  seq=" << seq
                      << " type=" << rec.type
                      << " target_pid=" << rec.target_pid
                      << " retry=" << rec.retry_count
                      << " elapsed=" << elapsed << "ms\n";
        }
    }
    if (!retry_queue_.empty()) {
        std::cout << "待重试队列 (" << retry_queue_.size() << "): ";
        for (auto& p : retry_queue_) {
            std::cout << p.second << "(" << p.first << ") ";
        }
        std::cout << "\n";
    }
    std::cout << "=========================================\n";
}

// ---------- EventLoop 实现 ----------

EventLoop::EventLoop() {
    epoll_fd_ = epoll_create1(0);
    if (epoll_fd_ == -1) {
        perror("epoll_create1");
        exit(1);
    }
    init_timerfd();
    add_fd(STDIN_FILENO, EPOLLIN);
}

EventLoop::~EventLoop() {
    if (timerfd_1s_ != -1) close(timerfd_1s_);
    if (timerfd_2s_ != -1) close(timerfd_2s_);
    if (timerfd_5s_ != -1) close(timerfd_5s_);
    if (epoll_fd_ != -1) close(epoll_fd_);
}

void EventLoop::init_timerfd() {
    // 1秒定时器：任务派发 + 超时检测
    timerfd_1s_ = timerfd_create(CLOCK_MONOTONIC, 0);
    struct itimerspec its1 = {{1, 0}, {1, 0}};
    timerfd_settime(timerfd_1s_, 0, &its1, nullptr);
    add_fd(timerfd_1s_, EPOLLIN);

    // 2秒定时器：看门狗心跳
    timerfd_2s_ = timerfd_create(CLOCK_MONOTONIC, 0);
    struct itimerspec its2 = {{HEARTBEAT_INTERVAL_SECS, 0}, {HEARTBEAT_INTERVAL_SECS, 0}};
    timerfd_settime(timerfd_2s_, 0, &its2, nullptr);
    add_fd(timerfd_2s_, EPOLLIN);

    // 5秒定时器：统计报告
    timerfd_5s_ = timerfd_create(CLOCK_MONOTONIC, 0);
    struct itimerspec its5 = {{5, 0}, {5, 0}};
    timerfd_settime(timerfd_5s_, 0, &its5, nullptr);
    add_fd(timerfd_5s_, EPOLLIN);
}

void EventLoop::add_fd(int fd, uint32_t events) {
    struct epoll_event ev;
    ev.events = events;
    ev.data.fd = fd;
    epoll_ctl(epoll_fd_, EPOLL_CTL_ADD, fd, &ev);
}

void EventLoop::del_fd(int fd) {
    epoll_ctl(epoll_fd_, EPOLL_CTL_DEL, fd, nullptr);
}

void EventLoop::process_stdin() {
    char cmd; ssize_t n = read(STDIN_FILENO, &cmd, 1);
    if (n <= 0) return;

    if (!manager_) return;

    if (cmd == '+') {
        manager_->add_worker();
    } else if (cmd == '-') {
        manager_->remove_worker();
    } else if (cmd == 's' || cmd == 'S') {
        manager_->print_statistics();
    } else if (cmd == 'i' || cmd == 'I') {
        manager_->print_worker_info();
    } else if (cmd == 'p' || cmd == 'P') {
        manager_->print_pending_tasks();
    } else if (cmd == 'q' || cmd == 'Q') {
        std::cout << "[CLI] 收到退出指令，正在优雅退出...\n";
        g_running = 0;
    }
}

void EventLoop::run() {
    std::cout << "\n提示：+ 增加 Worker  |  - 减少 Worker  |  "
              << "s 立即统计  |  i Worker详情  |  p 待追踪任务  |  q 退出\n";
    std::cout << "=====================================\n";

    struct epoll_event events[64];
    while (g_running) {
        int nfds = epoll_wait(epoll_fd_, events, 64, -1);
        if (nfds < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < nfds; ++i) {
            int fd = events[i].data.fd;
            if (fd == timerfd_1s_) {
                uint64_t exp;
                { uint64_t exp; (void)read(timerfd_1s_, &exp, sizeof(exp)); }
                if (manager_) {
                    manager_->dispatch_tasks();
                    manager_->check_timeouts();
                }
            } else if (fd == timerfd_2s_) {
                uint64_t exp;
                { uint64_t exp; (void)read(timerfd_2s_, &exp, sizeof(exp)); }
                if (manager_) {
                    manager_->send_ping_to_all();
                    manager_->check_heartbeat();
                }
            } else if (fd == timerfd_5s_) {
                uint64_t exp;
                { uint64_t exp; (void)read(timerfd_5s_, &exp, sizeof(exp)); }
                if (manager_) manager_->print_statistics();
            } else if (fd == STDIN_FILENO) {
                process_stdin();
            } else {
                if (manager_) manager_->handle_message(fd);
            }
        }
    }
}

int main(int argc, char* argv[]) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <N> (3~10)\n";
        return 1;
    }
    int N = atoi(argv[1]);
    if (N < 3 || N > 10) {
        std::cerr << "N must be between 3 and 10\n";
        return 1;
    }

    srand(time(nullptr));

    EventLoop loop;
    WorkerManager manager(&loop);
    loop.set_manager(&manager);

    g_worker_manager = &manager;
    signal(SIGUSR1, signal_handler);
    signal(SIGUSR2, signal_handler);
    signal(SIGINT,  shutdown_handler);
    signal(SIGTERM, shutdown_handler);

    for (int i = 0; i < N; ++i) manager.add_worker();

    std::cout << "系统启动，当前 Worker 数量: " << manager.size() << "\n";
    loop.run();

    manager.shutdown_and_wait();
    std::cout << "Manager 进程正常退出。\n";
    return 0;
}
