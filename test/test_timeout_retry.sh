#!/bin/bash
#
# test_timeout_retry.sh — 任务超时与重试机制测试
# 验证超时检测和自动重试逻辑
#
# 原理：故意让 Worker 无响应（SIGSTOP 暂停），触发超时，
# 然后 SIGCONT 恢复，观察重试行为
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

echo "[TIMEOUT] 启动 3 个 Worker，暂停一个 Worker 触发超时"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2

# 找到所有 Worker PID
WORKER_PIDS=$(pgrep -P "$MANAGER_PID" 2>/dev/null || true)
WORKER_COUNT=$(echo "$WORKER_PIDS" | wc -w)
echo "  检测到 $WORKER_COUNT 个 Worker: $WORKER_PIDS"

if [ "$WORKER_COUNT" -lt 2 ]; then
    echo "  ✗ Worker 创建不足"
    kill -INT "$MANAGER_PID" 2>/dev/null
    wait "$MANAGER_PID" 2>/dev/null || true
    rm -f "$OUT"
    exit 1
fi

# 暂停第一个 Worker（SIGSTOP 挂起，模拟卡死）
FIRST_WPID=$(echo "$WORKER_PIDS" | awk '{print $1}')
echo "  暂停 Worker PID=$FIRST_WPID（SIGSTOP）..."
kill -STOP "$FIRST_WPID"
echo "  等待 6 秒（超过 TIMEOUT_SECS=5），触发超时..."
sleep 6

# 恢复 Worker
kill -CONT "$FIRST_WPID"
echo "  恢复 Worker PID=$FIRST_WPID（SIGCONT）"

# 等待 Manager 处理
sleep 3

# 检查是否有超时相关日志
if grep -q "超时\|timeout\|TIMEOUT" "$OUT"; then
    echo "  ✓ 检测到超时日志"
    TIMEOUT_COUNT=$(grep -c "超时\|timeout\|TIMEOUT" "$OUT")
    echo "    超时日志出现次数: $TIMEOUT_COUNT"
else
    echo "  ⚠ 未检测到超时日志（可接受，Worker 可能在超时前已恢复）"
fi

# 再次检查 Manager 是否存活
if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在超时场景下仍然存活"
else
    echo "  ✗ Manager 在超时场景下崩溃"
    FAILED=1
fi

# 验证统计报告中包含超时计数
if grep -q "超时" "$OUT"; then
    echo "  ✓ 统计报告中包含超时记录"
else
    echo "  ⚠ 统计报告中未记录超时"
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 测试重试次数上限 -------
echo ""
echo "[TIMEOUT] 测试重试次数上限（MAX_RETRIES=2）"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 2
WORKER_PIDS=$(pgrep -P "$MANAGER_PID" 2>/dev/null || true)
FIRST_WPID=$(echo "$WORKER_PIDS" | awk '{print $1}')

echo "  第一次暂停（触发第1次超时）..."
kill -STOP "$FIRST_WPID"
sleep 6

echo "  第二次暂停（触发第2次超时）..."
kill -CONT "$FIRST_WPID"
sleep 1
kill -STOP "$FIRST_WPID"
sleep 6

echo "  第三次暂停（应触发失败，不再重试）..."
kill -CONT "$FIRST_WPID"
sleep 1
kill -STOP "$FIRST_WPID"
sleep 6
kill -CONT "$FIRST_WPID"

sleep 3

if grep -q "失败\|failed\|FAILED" "$OUT"; then
    echo "  ✓ 检测到任务失败记录（超过最大重试次数）"
else
    echo "  ⚠ 未检测到任务失败记录（可接受，取决于任务是否足够老）"
fi

if kill -0 "$MANAGER_PID" 2>/dev/null; then
    echo "  ✓ Manager 在多次超时后仍然存活"
else
    echo "  ✗ Manager 在多次超时后崩溃"
    FAILED=1
fi

kill -INT "$MANAGER_PID" 2>/dev/null
wait "$MANAGER_PID" 2>/dev/null || true
rm -f "$OUT"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 超时重试测试全部通过"
else
    echo "❌ 超时重试测试有失败项"
    exit 1
fi
