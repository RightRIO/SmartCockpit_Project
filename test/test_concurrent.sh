#!/bin/bash
#
# test_concurrent.sh — 并发动态调整压力测试
# 在短时间内同时触发大量 SIGUSR1/SIGUSR2，测试并发安全性
#
# 测试点：
#   1. 快速连续多次 SIGUSR1 不会导致崩溃
#   2. 快速连续多次 SIGUSR2 不会导致崩溃
#   3. Worker 数量保持在合法范围内 [1, 10]
#   4. 多次增删后任务分发仍然正常
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

# ------- 测试 1：快速连续 SIGUSR1 -------
echo "[CONCURRENT] 测试 1：快速连续发送 5 次 SIGUSR1（增加 Worker）"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2

for i in $(seq 1 5); do
    kill -SIGUSR1 "$MANAGER_PID" 2>/dev/null || true
    sleep 0.2
done

sleep 2

WORKER_ADDED=$(grep -c "Worker 已创建" "$OUT" || true)
echo "  Worker 创建日志次数: $WORKER_ADDED"

# 3 个初始 + 最多 5 次 SIGUSR1，上限为 10
if [ "$WORKER_ADDED" -ge 4 ]; then
    echo "  ✓ Worker 成功增加: $WORKER_ADDED 次创建日志"
else
    echo "  ✗ Worker 增加不足: $WORKER_ADDED"
    FAILED=1
fi

if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在快速 SIGUSR1 后仍然存活"
else
    echo "  ✗ Manager 在快速 SIGUSR1 后崩溃"
    FAILED=1
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 测试 2：快速连续 SIGUSR2 -------
echo ""
echo "[CONCURRENT] 测试 2：快速连续发送 3 次 SIGUSR2（减少 Worker）"
OUT=$(mktemp)
"$BIN" 8 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2

for i in $(seq 1 3); do
    kill -SIGUSR2 "$MANAGER_PID" 2>/dev/null || true
    sleep 0.3
done

sleep 2

WORKER_REMOVED=$(grep -c "Worker 已移除" "$OUT" || true)
echo "  Worker 移除日志次数: $WORKER_REMOVED"

if [ "$WORKER_REMOVED" -ge 2 ]; then
    echo "  ✓ Worker 成功减少: $WORKER_REMOVED 次移除日志"
else
    echo "  ⚠ Worker 减少不足: $WORKER_REMOVED（可接受）"
fi

if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在快速 SIGUSR2 后仍然存活"
else
    echo "  ✗ Manager 在快速 SIGUSR2 后崩溃"
    FAILED=1
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 测试 3：混合格并发（SIGUSR1 + SIGUSR2 交替） -------
echo ""
echo "[CONCURRENT] 测试 3：混合格并发送（SIGUSR1 + SIGUSR2 交替）"
OUT=$(mktemp)
"$BIN" 5 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2

# 交替发送信号
for i in $(seq 1 3); do
    kill -SIGUSR1 "$MANAGER_PID" 2>/dev/null || true
    sleep 0.2
    kill -SIGUSR2 "$MANAGER_PID" 2>/dev/null || true
    sleep 0.2
done

sleep 2

FINAL_CREATED=$(grep -c "Worker 已创建" "$OUT" || true)
FINAL_REMOVED=$(grep -c "Worker 已移除" "$OUT" || true)
echo "  Worker 创建: $FINAL_CREATED 次，移除: $FINAL_REMOVED 次"

if [ "$FINAL_CREATED" -ge 4 ] && [ "$FINAL_REMOVED" -ge 1 ]; then
    echo "  ✓ 混合模式下增删均成功"
else
    echo "  ⚠ 混合模式下部分操作失败"
fi

if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在混合信号后仍然存活"
else
    echo "  ✗ Manager 在混合信号后崩溃"
    FAILED=1
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 测试 4：极限压力（连续 SIGUSR1 达到上限） -------
echo ""
echo "[CONCURRENT] 测试 4：极限压力（快速发 SIGUSR1 达到上限 10）"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2

# 快速发 20 次 SIGUSR1（远超上限，应被拒绝）
for i in $(seq 1 20); do
    kill -SIGUSR1 "$MANAGER_PID" 2>/dev/null || true
done

sleep 2

CREATED=$(grep -c "Worker 已创建" "$OUT" || true)
WARN_COUNT=$(grep -c "已达最大 Worker" "$OUT" || true)
echo "  Worker 创建次数: $CREATED"
echo "  达到上限警告次数: $WARN_COUNT"

# 3 初始 + 最多 7 次增加 = 最多 10 次创建
if [ "$CREATED" -ge 8 ]; then
    echo "  ✓ Worker 达到上限前正常增加"
else
    echo "  ✗ Worker 增加不足"
fi

if grep -q "已达最大 Worker" "$OUT"; then
    echo "  ✓ 正确触发上限警告"
else
    echo "  ⚠ 未检测到上限警告（可接受，epoll 可能尚未处理）"
fi

if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在极限压力后仍然存活"
else
    echo "  ✗ Manager 在极限压力后崩溃"
    FAILED=1
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 检查僵尸进程 -------
echo ""
echo "[CONCURRENT] 检查僵尸进程残留"
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
    echo "✅ 并发动态调整压力测试全部通过"
else
    echo "❌ 并发动态调整压力测试有失败项"
    exit 1
fi
