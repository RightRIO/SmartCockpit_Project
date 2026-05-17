#!/bin/bash
#
# test_boundary.sh — 边界值测试
# 测试 N=3（最小合法值）和 N=10（最大合法值）的启动与正常运行
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

echo "[TEST] N=3 (最小边界) — 启动 6 秒，观察是否正常"
OUTPUT=$(timeout 6s "$BIN" 3 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 124 ]; then
    echo "  ✓ 正常运行 6 秒后超时退出（预期行为）" 
else
    echo "  ✗ 非预期退出，exit code=$EXIT_CODE"
    FAILED=1
fi

if echo "$OUTPUT" | grep -q "Worker"; then
    echo "  ✓ Worker 创建日志正常"
else
    echo "  ✗ 未检测到 Worker 创建日志"
    FAILED=1
fi

if echo "$OUTPUT" | grep -q "统计报告"; then
    echo "  ✓ 统计报告正常输出"
else
    echo "  ✗ 未检测到统计报告"
    FAILED=1
fi

echo ""
echo "[TEST] N=10 (最大边界) — 启动 6 秒，观察是否正常"
OUTPUT=$(timeout 6s "$BIN" 10 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 124 ]; then
    echo "  ✓ 正常运行 6 秒后超时退出（预期行为）"
else
    echo "  ✗ 非预期退出，exit code=$EXIT_CODE"
    FAILED=1
fi

WORKER_COUNT=$(echo "$OUTPUT" | grep -c "增加 Worker 成功")
if [ "$WORKER_COUNT" -ge 9 ]; then
    echo "  ✓ 检测到 $WORKER_COUNT 次 Worker 创建（N≈10）"
else
    echo "  ✗ Worker 创建次数不足: $WORKER_COUNT"
    FAILED=1
fi

echo ""
echo "[TEST] N=2 (非法值) — 应拒绝启动"
if timeout 2s "$BIN" 2 2>&1 | grep -q "N must be between"; then
    echo "  ✓ 正确拒绝非法参数 N=2"
else
    echo "  ✗ 未检测到参数校验错误"
    FAILED=1
fi

echo ""
echo "[TEST] N=11 (非法值) — 应拒绝启动"
if timeout 2s "$BIN" 11 2>&1 | grep -q "N must be between"; then
    echo "  ✓ 正确拒绝非法参数 N=11"
else
    echo "  ✗ 未检测到参数校验错误"
    FAILED=1
fi

echo ""
echo "[TEST] 无参数 — 应显示用法"
if timeout 2s "$BIN" 2>&1 | grep -q "Usage:"; then
    echo "  ✓ 无参数时正确显示 Usage"
else
    echo "  ✗ 未检测到 Usage 提示"
    FAILED=1
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 边界测试全部通过"
else
    echo "❌ 边界测试有失败项"
    exit 1
fi
