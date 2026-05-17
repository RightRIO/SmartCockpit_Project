#!/bin/bash
#
# test_signal.sh — 信号处理测试
# 验证 SIGINT、SIGTERM、SIGUSR1、SIGUSR2 四种信号的行为
#
# 测试点：
#   1. SIGINT（Ctrl+C）触发优雅退出
#   2. SIGTERM（kill 默认信号）触发优雅退出
#   3. SIGUSR1 增加 Worker
#   4. SIGUSR2 减少 Worker
#   5. 退出后无僵尸进程
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

# ------- 测试 SIGINT -------
echo "[SIGNAL] 测试 SIGINT 优雅退出"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2
WORKER_BEFORE=$(grep -c "Worker 已创建" "$OUT" || true)

kill -INT "$MANAGER_PID"
wait "$MANAGER_PID" 2>/dev/null || true

sleep 1

if grep -q "优雅退出\|SHUTDOWN\|已回收" "$OUT"; then
    echo "  ✓ SIGINT 触发优雅退出流程"
else
    echo "  ✗ SIGINT 后未检测到优雅退出日志"
    FAILED=1
fi

if grep -q "Worker.*已回收" "$OUT"; then
    echo "  ✓ 检测到子进程回收日志"
else
    echo "  ⚠ 未检测到子进程回收日志（可接受）"
fi

# ------- 测试 SIGTERM -------
echo ""
echo "[SIGNAL] 测试 SIGTERM 优雅退出"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2
kill -TERM "$MANAGER_PID"
wait "$MANAGER_PID" 2>/dev/null || true

sleep 1

if grep -q "优雅退出\|SHUTDOWN\|已回收" "$OUT"; then
    echo "  ✓ SIGTERM 触发优雅退出流程"
else
    echo "  ✗ SIGTERM 后未检测到优雅退出日志"
    FAILED=1
fi

# ------- 测试 SIGUSR1 -------
echo ""
echo "[SIGNAL] 测试 SIGUSR1 增加 Worker"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2
BEFORE=$(grep -c "Worker 已创建" "$OUT" || true)
kill -USR1 "$MANAGER_PID"
sleep 1
AFTER=$(grep -c "Worker 已创建" "$OUT" || true)

if [ "$AFTER" -gt "$BEFORE" ]; then
    echo "  ✓ SIGUSR1 增加 Worker: $BEFORE -> $AFTER"
else
    echo "  ✗ SIGUSR1 后 Worker 未增加: $BEFORE -> $AFTER"
    FAILED=1
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 测试 SIGUSR2 -------
echo ""
echo "[SIGNAL] 测试 SIGUSR2 减少 Worker"
OUT=$(mktemp)
"$BIN" 5 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2
BEFORE=$(grep -c "Worker 已创建" "$OUT" || true)
kill -USR2 "$MANAGER_PID"
sleep 1
AFTER=$(grep -c "Worker 已创建" "$OUT" || true)

if [ "$AFTER" -lt "$BEFORE" ]; then
    echo "  ✓ SIGUSR2 减少 Worker: $BEFORE -> $AFTER"
else
    echo "  ✗ SIGUSR2 后 Worker 未减少: $BEFORE -> $AFTER"
    FAILED=1
fi

if grep -q "Worker 已移除" "$OUT"; then
    echo "  ✓ 检测到 Worker 移除日志"
else
    echo "  ⚠ 未检测到移除日志（可接受）"
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 检查僵尸进程 -------
echo ""
echo "[SIGNAL] 检查僵尸进程残留"
ZOMBIES=$(ps -A -o pid,stat | grep -c ' Z ' || true)
if [ "$ZOMBIES" -eq 0 ]; then
    echo "  ✓ 无僵尸进程"
else
    echo "  ✗ 发现 $ZOMBIES 个僵尸进程"
    FAILED=1
fi

rm -f "$OUT"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 信号处理测试全部通过"
else
    echo "❌ 信号处理测试有失败项"
    exit 1
fi
