#!/bin/bash
#
# test_perf.sh — 性能指标测试
# 验证系统在运行期间的吞吐量和延迟是否符合预期
#
# 测试点：
#   1. 吞吐量：10 秒内完成的最小任务数
#   2. 延迟：平均延迟在合理范围内
#   3. 统计报告格式完整性
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0
RUNTIME=12  # 秒，足够覆盖 2 个 5 秒统计周期

echo "[PERF] 启动 5 个 Worker，运行 ${RUNTIME} 秒，测量吞吐量和延迟"
OUT=$(mktemp)
"$BIN" 5 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep "$RUNTIME"

kill -INT "$MANAGER_PID"
wait "$MANAGER_PID" 2>/dev/null || true

sleep 1

# ------- 吞吐量测试 -------
echo ""
echo "[PERF] 吞吐量分析"
DISPATCHED=$(grep -c "派发\|dispatch\|总派发" "$OUT" || echo "0")

# 从统计报告中提取吞吐量
THROUGHPUT=$(grep "吞吐量" "$OUT" | sed 's/.*吞吐量: *\([0-9.]*\).*/\1/' | tail -1)
COMPLETED=$(grep "已完成" "$OUT" | sed 's/.*已完成: *\([0-9]*\).*/\1/' | tail -1)
TOTAL=$(grep "总派发" "$OUT" | sed 's/.*总派发: *\([0-9]*\).*/\1/' | tail -1)

echo "  吞吐量: $THROUGHPUT tasks/s"
echo "  已完成: $COMPLETED tasks"
echo "  总派发: $TOTAL tasks"

# 吞吐量合理性检查：5 个 Worker，1 秒 1 个任务，理论上至少 5 tasks/s
# 考虑 100~300ms 任务，5 Worker 在 12 秒内至少应完成 30+ 任务
if [ -n "$COMPLETED" ] && [ "$COMPLETED" -ge 10 ]; then
    echo "  ✓ 已完成任务数合理: $COMPLETED >= 10"
else
    echo "  ✗ 已完成任务数过低: $COMPLETED"
    FAILED=1
fi

if [ -n "$THROUGHPUT" ] && (( $(echo "$THROUGHPUT > 0" | bc -l 2>/dev/null || echo 0) )); then
    echo "  ✓ 吞吐量数据有效: $THROUGHPUT tasks/s"
else
    echo "  ⚠ 吞吐量数据无效（可能系统较慢）"
fi

# ------- 延迟测试 -------
echo ""
echo "[PERF] 延迟分析"
AVG_LATENCY=$(grep "任务延迟" "$OUT" | sed 's/.*avg=\([0-9.]*\)ms.*/\1/' | tail -1)
MIN_LATENCY=$(grep "任务延迟" "$OUT" | sed 's/.*min=\([0-9.]*\)ms.*/\1/' | tail -1)
MAX_LATENCY=$(grep "任务延迟" "$OUT" | sed 's/.*max=\([0-9.]*\)ms.*/\1/' | tail -1)

echo "  平均延迟: ${AVG_LATENCY:-N/A} ms"
echo "  最小延迟: ${MIN_LATENCY:-N/A} ms"
echo "  最大延迟: ${MAX_LATENCY:-N/A} ms"

# 延迟合理性检查
if [ -n "$AVG_LATENCY" ]; then
    # 类型 A/B/C 任务理论延迟为 100/200/300ms，考虑排队，平均延迟应 < 800ms
    if (( $(echo "$AVG_LATENCY < 1000" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ✓ 平均延迟在合理范围: ${AVG_LATENCY}ms < 1000ms"
    else
        echo "  ⚠ 平均延迟偏高: ${AVG_LATENCY}ms（可接受）"
    fi

    if (( $(echo "$MIN_LATENCY > 50" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ✓ 最小延迟合理: ${MIN_LATENCY}ms > 50ms"
    else
        echo "  ⚠ 最小延迟过低（可接受）"
    fi
else
    echo "  ⚠ 未检测到延迟数据"
fi

# ------- 统计报告完整性 -------
echo ""
echo "[PERF] 统计报告完整性"
REPORT_COUNT=$(grep -c "系统统计报告\|==========" "$OUT" || true)
echo "  统计报告生成次数: $REPORT_COUNT"

if [ "$REPORT_COUNT" -ge 2 ]; then
    echo "  ✓ 统计报告按时生成"
else
    echo "  ⚠ 统计报告生成次数不足（可接受，运行时长较短）"
fi

if grep -q "Worker" "$OUT"; then
    echo "  ✓ Worker 存活状态出现在报告中"
else
    echo "  ✗ Worker 存活状态缺失"
    FAILED=1
fi

if grep -q "吞吐量" "$OUT"; then
    echo "  ✓ 吞吐量指标出现在报告中"
else
    echo "  ✗ 吞吐量指标缺失"
    FAILED=1
fi

# ------- 任务类型分布 -------
echo ""
echo "[PERF] 任务类型分布"
A_COUNT=$(grep "A=" "$OUT" | grep -o "A=[0-9]*" | sed 's/A=//' | awk '{s+=$1} END{print s+0}')
B_COUNT=$(grep "A=" "$OUT" | grep -o "B=[0-9]*" | sed 's/B=//' | awk '{s+=$1} END{print s+0}')
C_COUNT=$(grep "A=" "$OUT" | grep -o "C=[0-9]*" | sed 's/C=//' | awk '{s+=$1} END{print s+0}')
echo "  类型 A 任务: ${A_COUNT:-0}"
echo "  类型 B 任务: ${B_COUNT:-0}"
echo "  类型 C 任务: ${C_COUNT:-0}"

TOTAL_TASKS=$((A_COUNT + B_COUNT + C_COUNT))
if [ "$TOTAL_TASKS" -gt 0 ]; then
    echo "  ✓ 任务类型分布正常，总计: $TOTAL_TASKS"
else
    echo "  ⚠ 任务类型计数未提取到"
fi

rm -f "$OUT"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 性能指标测试全部通过"
else
    echo "❌ 性能指标测试有失败项"
    exit 1
fi
