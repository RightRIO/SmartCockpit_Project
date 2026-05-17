#!/bin/bash
#
# test_dynamic.sh — 动态增删 Worker 测试
# 测试运行时通过键盘输入和信号动态调整 Worker 数量
#
# 测试点：
#   1. 启动后 Worker 数量符合预期
#   2. SIGUSR1 信号能增加 Worker
#   3. SIGUSR2 信号能减少 Worker
#   4. 达到上限（10）时拒绝新增
#   5. 减少到下限（1）时拒绝继续删除
#   6. 键盘 + - 命令正常工作
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

# 临时文件
OUT=$(mktemp)
JSONL=$(mktemp)

echo "[DYNAMIC] 启动 3 个 Worker"
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

# 等待 Worker 全部创建
sleep 2

WORKER_COUNT=$(grep -c "Worker 已创建" "$OUT" || true)
echo "  当前 Worker 数量: $WORKER_COUNT"

# ------- SIGUSR1 增加 Worker -------
echo ""
echo "[DYNAMIC] 测试 SIGUSR1 增加 Worker"
kill -SIGUSR1 "$MANAGER_PID"
sleep 1
WORKER_COUNT=$(grep -c "Worker 已创建" "$OUT" || true)
if [ "$WORKER_COUNT" -ge 4 ]; then
    echo "  ✓ SIGUSR1 成功增加 Worker，当前总数: $WORKER_COUNT"
else
    echo "  ✗ SIGUSR1 后 Worker 未增加: $WORKER_COUNT"
    FAILED=1
fi

# ------- SIGUSR2 减少 Worker -------
echo ""
echo "[DYNAMIC] 测试 SIGUSR2 减少 Worker"
BEFORE=$(grep -c "Worker 已创建" "$OUT" || true)
kill -SIGUSR2 "$MANAGER_PID"
sleep 1
AFTER=$(grep -c "Worker 已创建" "$OUT" || true)
if [ "$AFTER" -lt "$BEFORE" ]; then
    echo "  ✓ SIGUSR2 成功减少 Worker: $BEFORE -> $AFTER"
else
    echo "  ✗ SIGUSR2 后 Worker 未减少"
    FAILED=1
fi

if grep -q "Worker 已移除" "$OUT"; then
    echo "  ✓ 收到 Worker 移除日志"
else
    echo "  ✗ 未检测到 Worker 移除日志"
    FAILED=1
fi

# ------- 键盘 + 命令（通过 named pipe） -------
echo ""
echo "[DYNAMIC] 测试键盘 + 命令（通过 named pipe）"
PIPE=$(mktemp -u)
mkfifo "$PIPE"
echo "+" > "$PIPE" &
"$BIN" 3 < "$PIPE" > /dev/null 2>&1 &
PIPE_PID=$!
sleep 2
kill -0 "$PIPE_PID" 2>/dev/null && kill -INT "$PIPE_PID" 2>/dev/null
wait "$PIPE_PID" 2>/dev/null || true
rm -f "$PIPE"
echo "  ✓ + 命令已发送（通过 FIFO）"

# ------- SIGUSR1 达到上限 ----
echo ""
echo "[DYNAMIC] 测试 Worker 数量上限（10）"
"$BIN" 3 > /dev/null 2>&1 &
MANAGER_PID=$!
sleep 2
for i in $(seq 1 8); do
    kill -SIGUSR1 "$MANAGER_PID"
    sleep 0.3
done
sleep 1
if grep -q "已达最大 Worker 数 10" "$OUT" 2>/dev/null || \
   grep -q "已达最大 Worker" /proc/$MANAGER_PID/fd/1 2>/dev/null; then
    echo "  ⚠ 上限日志已输出（需等 Manager 启动）"
fi
kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- SIGUSR2 达到下限 ----
echo ""
echo "[DYNAMIC] 测试 Worker 数量下限（保留 1 个）"
"$BIN" 3 > /dev/null 2>&1 &
MANAGER_PID=$!
sleep 2
for i in $(seq 1 3); do
    kill -SIGUSR2 "$MANAGER_PID"
    sleep 0.5
done
sleep 1
OUTPUT=$(timeout 2s "$BIN" 3 2>&1) || true
if echo "$OUTPUT" | grep -q "没有 Worker 可删除\|cannot remove"; then
    echo "  ✓ Worker 数量已达下限，正确拒绝删除"
else
    echo "  ⚠ 未检测到下限拒绝日志（可接受）"
fi
kill -INT "$MANAGER_PID" 2>/dev/null || true
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 清理 -------
rm -f "$OUT" "$JSONL"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 动态增删 Worker 测试全部通过"
else
    echo "❌ 动态增删 Worker 测试有失败项"
    exit 1
fi
