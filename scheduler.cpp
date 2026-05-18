#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <iostream>
#include <vector>
#include <memory>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <sys/wait.h>
#include <signal.h>
#include <ctime>
#include <cstdlib>


class EventLoop;

//消息定义
#pragma pack(1)
struct TaskMsg {
    char type;
    uint32_t seq;
};

struct DoneMsg {
    char type;
    uint32_t seq;
};
#pragma pack()

const char TASK_A = 'A';
const char TASK_B = 'B';
const char TASK_C = 'C';

//通信通道
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

    bool send_task(char type, uint32_t seq) {
        TaskMsg msg{type, seq};
        return send(fd_, &msg, sizeof(msg), 0) == sizeof(msg);
    }

    bool send_exit() {
        TaskMsg msg{'X', 0};
        return send(fd_, &msg, sizeof(msg), 0) == sizeof(msg);
    }

    bool send_done(char type, uint32_t seq) {
        DoneMsg msg{type, seq};
        return send(fd_, &msg, sizeof(msg), 0) == sizeof(msg);
    }

    bool recv_done(char& type, uint32_t& seq) {
        DoneMsg msg;
        ssize_t n = recv(fd_, &msg, sizeof(msg), 0);
        if (n != sizeof(msg)) return false;
        type = msg.type;
        seq = msg.seq;
        return true;
    }

    bool recv_task(char& type, uint32_t& seq) {
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

//worker数据结构
struct Worker {
    pid_t pid;
    std::unique_ptr<IpcChannel> channel;
    int task_count = 0;
    int type_count[3] = {0, 0, 0};
    bool alive = true;
};

//Worker管理类
class WorkerManager {
public:
    explicit WorkerManager(EventLoop* loop) : loop_(loop) {}

    void add_worker();
    void remove_worker();
    void remove_worker_by_fd(int fd);
    void shutdown_and_wait();

    void dispatch_tasks();
    void handle_message(int fd);
    void print_statistics();

    size_t size() const { return workers_.size(); }

private:
    std::vector<Worker> workers_;
    EventLoop* loop_;
    uint32_t next_seq_ = 1;

    static void worker_main(int fd);
};

//事件循环类
class EventLoop {
public:
    EventLoop();
    ~EventLoop();

    void add_fd(int fd, uint32_t events);
    void del_fd(int fd);
    void set_manager(WorkerManager* mgr) { manager_ = mgr; }

    void run();

private:
    int epoll_fd_;
    int timerfd_1s_;
    int timerfd_5s_;
    WorkerManager* manager_ = nullptr;

    void init_timerfd();
    void process_stdin();   // 处理键盘输入
};

//全局变量，用于信号处理
WorkerManager* g_worker_manager = nullptr;
volatile sig_atomic_t g_running = 1;

void signal_handler(int sig) {
    if (!g_worker_manager) return;
    if (sig == SIGUSR1)      g_worker_manager->add_worker();
    else if (sig == SIGUSR2) g_worker_manager->remove_worker();
}

void shutdown_handler(int sig) {
    (void)sig;
    g_running = 0;
}

//WorkerManager实现
char get_random_task() {
    int r = rand() % 3;
    return (r == 0) ? TASK_A : (r == 1) ? TASK_B : TASK_C;
}

void WorkerManager::add_worker() {
    if (workers_.size() >= 10) {
        std::cout << "已达到最大 Worker 数 10\n";
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
        loop_->add_fd(w.channel->get_fd(), EPOLLIN);
        workers_.push_back(std::move(w));
        std::cout << "增加 Worker 成功，当前数量: " << workers_.size() << std::endl;
    } else {
        perror("fork");
    }
}

void WorkerManager::remove_worker() {
    if (workers_.empty()) {
        std::cout << "没有 Worker 可删除\n";
        return;
    }

    Worker& last = workers_.back();
    last.channel->send_exit();
    int status;
    waitpid(last.pid, &status, 0);
    loop_->del_fd(last.channel->get_fd());
    workers_.pop_back();
    std::cout << "减少 Worker 成功，当前数量: " << workers_.size() << std::endl;
}

void WorkerManager::remove_worker_by_fd(int fd) {
    for (auto it = workers_.begin(); it != workers_.end(); ++it) {
        if (it->channel && it->channel->get_fd() == fd) {
            std::cout << "Worker (PID " << it->pid << ") 异常，移除中...\n";
            it->channel->send_exit();
            waitpid(it->pid, nullptr, WNOHANG);
            loop_->del_fd(fd);
            workers_.erase(it);
            std::cout << "当前 Worker 数量: " << workers_.size() << std::endl;
            return;
        }
    }
}

void WorkerManager::shutdown_and_wait() {
    std::cout << "\n正在向所有 Worker 发送退出信号（优雅退出）...\n";

    for (auto& w : workers_) {
        if (w.alive && w.channel) {
            w.channel->send_exit();
        }
    }

    if (workers_.empty()) {
        std::cout << "所有 Worker 已在此前异常退出，无需额外清理。\n";
        return;
    }

    for (auto& w : workers_) {
        int status;
        waitpid(w.pid, &status, 0);
        std::cout << "Worker (PID " << w.pid << ") 已回收，退出状态: "
                  << WEXITSTATUS(status) << std::endl;
    }
    workers_.clear();
    std::cout << "所有 Worker 已优雅退出，无僵尸进程残留。\n";
}

void WorkerManager::dispatch_tasks() {
    // 清理失效 Worker
    for (auto it = workers_.begin(); it != workers_.end(); ) {
        if (!it->alive || !it->channel) {
            if (it->channel) loop_->del_fd(it->channel->get_fd());
            it = workers_.erase(it);
        } else {
            ++it;
        }
    }

    for (auto& w : workers_) {
        char task = get_random_task();
        uint32_t seq = next_seq_++;
        if (!w.channel->send_task(task, seq)) {
            std::cerr << "发送任务到 Worker " << w.pid << " 失败，标记为异常\n";
            w.alive = false;
        }
    }
}

void WorkerManager::handle_message(int fd) {
    Worker* target = nullptr;
    for (auto& w : workers_) {
        if (w.channel && w.channel->get_fd() == fd) {
            target = &w;
            break;
        }
    }
    if (!target) return;

    char type;
    uint32_t seq;
    if (!target->channel->recv_done(type, seq)) {
        std::cerr << "与 Worker (PID " << target->pid << ") 通信失败，移除\n";
        target->alive = false;
        return;
    }

    target->task_count++;
    if (type == TASK_A)      target->type_count[0]++;
    else if (type == TASK_B) target->type_count[1]++;
    else if (type == TASK_C) target->type_count[2]++;
}

void WorkerManager::print_statistics() {
    static time_t last_time = time(nullptr);
    time_t now = time(nullptr);
    int total_tasks = 0, total_A = 0, total_B = 0, total_C = 0;
    for (auto& w : workers_) {
        total_tasks += w.task_count;
        total_A += w.type_count[0];
        total_B += w.type_count[1];
        total_C += w.type_count[2];
    }
    std::cout << "\n========== 统计报告 (间隔 " << (now - last_time) << " 秒) ==========\n";
    std::cout << "总任务数: " << total_tasks << "  (A:" << total_A << " B:" << total_B << " C:" << total_C << ")\n";
    std::cout << "各Worker任务数: ";
    for (size_t i = 0; i < workers_.size(); ++i)
        std::cout << "W" << i+1 << ":" << workers_[i].task_count << " ";
    std::cout << "\n=========================================================\n";
    last_time = now;
}

void WorkerManager::worker_main(int fd) {
    IpcChannel channel(fd);
    int task_count = 0;
    int type_cnt[3] = {0};

    while (true) {
        char type;
        uint32_t seq;
        if (!channel.recv_task(type, seq)) break;

        if (type == 'X') {
            std::cout << "Worker " << getpid() << " final stats: total=" << task_count
                      << " A=" << type_cnt[0] << " B=" << type_cnt[1] << " C=" << type_cnt[2] << std::endl;
            break;
        }

        int sleep_ms = (type == 'A') ? 100 : (type == 'B') ? 200 : 300;
        usleep(sleep_ms * 1000);

        if (!channel.send_done(type, seq)) break;

        task_count++;
        if (type == 'A')      type_cnt[0]++;
        else if (type == 'B') type_cnt[1]++;
        else if (type == 'C') type_cnt[2]++;
    }
}

EventLoop::EventLoop() {
    epoll_fd_ = epoll_create1(0);
    if (epoll_fd_ == -1) {
        perror("epoll_create1");
        exit(1);
    }
    init_timerfd();

    // 将标准输入加入 epoll 监听
    add_fd(STDIN_FILENO, EPOLLIN);
}

EventLoop::~EventLoop() {
    if (timerfd_1s_ != -1) close(timerfd_1s_);
    if (timerfd_5s_ != -1) close(timerfd_5s_);
    if (epoll_fd_  != -1) close(epoll_fd_);
}

void EventLoop::init_timerfd() {
    timerfd_1s_ = timerfd_create(CLOCK_MONOTONIC, 0);
    struct itimerspec its1 = {{1, 0}, {1, 0}};
    timerfd_settime(timerfd_1s_, 0, &its1, nullptr);
    add_fd(timerfd_1s_, EPOLLIN);

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
    char cmd;
    ssize_t n = read(STDIN_FILENO, &cmd, 1);
    if (n <= 0) return;

    if (cmd == '+') {
        if (manager_) manager_->add_worker();
    } else if (cmd == '-') {
        if (manager_) manager_->remove_worker();
    }
    
}

void EventLoop::run() {
    std::cout << "\n提示：直接在终端按 '+' 增加 Worker，按 '-' 减少 Worker\n";
    struct epoll_event events[10];
    while (g_running) {
        int nfds = epoll_wait(epoll_fd_, events, 10, -1);
        if (nfds < 0) break;
        for (int i = 0; i < nfds; ++i) {
            int fd = events[i].data.fd;
            if (fd == timerfd_1s_) {
                uint64_t exp;
                (void)read(timerfd_1s_, &exp, sizeof(exp));
                if (manager_) manager_->dispatch_tasks();
            } else if (fd == timerfd_5s_) {
                uint64_t exp;
                (void)read(timerfd_5s_, &exp, sizeof(exp));
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

    std::cout << "系统启动，当前 Worker 数量: " << manager.size() << std::endl;
    loop.run();

    manager.shutdown_and_wait();
    std::cout << "Manager 进程正常退出。\n";
    return 0;
}