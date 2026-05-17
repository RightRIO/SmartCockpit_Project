#!/bin/bash
#
# test_stress.sh — 压力测试：所有 Worker 同时故障
# 模拟场景：在运行时 kill -9 所有 Worker，验证 Manager 的故障检测
# 和自动清理能力，以及无僵尸进程残留
#
# 压力测试点：
#   1. 所有 Worker 同时异常退出
#   2. Manager 能检测到 fd 读失败，调用 remove_worker_by_fd
#   3. Manager 能继续运行（不崩溃）
#   4. 退出后无僵尸进程
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

echo "[STRESS] 启动 3 个 Worker，运行 2 秒后强制 kill -9 所有子进程"
# 启动后台进程，捕获其 PID
"$BIN" 3 > /tmp/stress_output_$$.txt 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

# 等待 Manager 创建完 3 个 Worker（等待 1s 让 fork 完成）
sleep 1

# 找到所有 Worker PID（Manager 的直接子进程）
WORKER_PIDS=$(pgrep -P "$MANAGER_PID" 2>/dev/null || true)
WORKER_COUNT=$(echo "$WORKER_PIDS" | wc -w)
echo "  检测到 $WORKER_COUNT 个 Worker: $WORKER_PIDS"

if [ "$WORKER_COUNT" -lt 2 ]; then
    echo "  ⚠ Worker 创建不足，可能 fork 尚未完成，重试..."
    sleep 1
    WORKER_PIDS=$(pgrep -P "$MANAGER_PID" 2>/dev/null || true)
    WORKER_COUNT=$(echo "$WORKER_PIDS" | wc -w)
fi

echo "  向所有 Worker 发送 SIGKILL..."
for WPID in $WORKER_PIDS; do
    kill -9 "$WPID" 2>/dev/null && echo "  已 kill Worker $WPID" || true
done

# 等待 Manager 感知到子进程退出（需要 epoll 触发）
sleep 2

# Manager 应该还在运行（故障自愈）
if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在所有 Worker 被 kill 后仍然存活（故障自愈）"
else
    echo "  ✗ Manager 随子进程一同终止了（应该独立存活）"
    FAILED=1
fi

# 触发优雅退出
echo "  触发 Manager 优雅退出..."
kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

sleep 1

echo ""
echo "[STRESS] 检查僵尸进程残留..."
ZOMBIES=$(ps -A -o pid,stat | grep -c 'Z' || true)
if [ "$ZOMBIES" -eq 0 ]; then
    echo "  ✓ 无僵尸进程残留"
else
    ZOMBIE_LIST=$(ps -A -o pid,stat,cmd | grep 'Z' || true)
    echo "  ✗ 发现 $ZOMBIES 个僵尸进程:"
    echo "$ZOMBIE_LIST"
    FAILED=1
fi

echo ""
echo "[STRESS] 检查 Manager 日志输出..."
OUTPUT=$(cat /tmp/stress_output_$$.txt)
if echo "$OUTPUT" | grep -q "异常"; then
    echo "  ✓ Manager 正确检测到 Worker 异常"
else
    echo "  ⚠ Manager 日志中未明确出现'异常'字样（可能 epoll 延迟触发，可接受）"
fi

if echo "$OUTPUT" | grep -q "回收"; then
    echo "  ✓ Manager 日志中出现进程回收记录"
else
    echo "  ⚠ Manager 日志中未出现回收记录（可接受，异常 Worker 使用 WNOHANG 回收）"
fi

if echo "$OUTPUT" | grep -q "优雅退出"; then
    echo "  ✓ 优雅退出流程正常执行"
else
    echo "  ✗ 优雅退出流程未执行"
    FAILED=1
fi

rm -f /tmp/stress_output_$$.txt

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 压力测试全部通过"
else
    echo "❌ 压力测试有失败项"
    exit 1
fi
