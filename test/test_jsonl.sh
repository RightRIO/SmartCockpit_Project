#!/bin/bash
#
# test_jsonl.sh — JSONL 结构化日志格式验证
# 验证生成的 .jsonl 日志文件格式正确且包含必要字段
#
# 依赖：jq（JSON 解析工具）
#

set -e

BIN="$1"
if [ -z "$BIN" ]; then
    echo "Usage: bash $0 <path-to-scheduler-binary>"
    exit 1
fi

FAILED=0

echo "[JSONL] 检查 jq 是否可用..."
if command -v jq &>/dev/null; then
    echo "  jq 可用，开始验证 JSONL 格式"
else
    echo "  ⚠ jq 未安装，将使用基础正则验证"
fi

# ------- 测试 1：启动生成 jsonl 文件 -------
echo ""
echo "[JSONL] 测试 1：启动生成 jsonl 文件"
OUT=$(mktemp)
"$BIN" 3 > "$OUT" 2>&1 &
MANAGER_PID=$!
echo "  Manager PID: $MANAGER_PID"

sleep 3

# 找到最新的 jsonl 文件
JSONL=$(ls -t scheduler_*.jsonl 2>/dev/null | head -1)
if [ -n "$JSONL" ] && [ -f "$JSONL" ]; then
    echo "  ✓ 找到 JSONL 文件: $JSONL"
    echo "  文件大小: $(wc -c < "$JSONL") 字节"
else
    echo "  ✗ 未找到 JSONL 文件"
    FAILED=1
    kill -INT "$MANAGER_PID" 2>/dev/null
    wait "$MANAGER_PID" 2>/dev/null || true
    rm -f "$OUT"
    exit 1
fi

kill -INT "$MANAGER_PID"
wait "$MANAGER_PID" 2>/dev/null || true

# ------- 测试 2：每行是否为合法 JSON -------
echo ""
echo "[JSONL] 测试 2：每行是否为合法 JSON"
if command -v jq &>/dev/null; then
    INVALID_LINES=0
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            if ! echo "$line" | jq -e . >/dev/null 2>&1; then
                echo "  ✗ 非法 JSON 行: $line"
                INVALID_LINES=$((INVALID_LINES + 1))
            fi
        fi
    done < "$JSONL"
    if [ "$INVALID_LINES" -eq 0 ]; then
        echo "  ✓ 所有 $(wc -l < "$JSONL") 行均为合法 JSON"
    else
        echo "  ✗ 发现 $INVALID_LINES 行非法 JSON"
        FAILED=1
    fi
else
    # 基础正则检查：每行以 { 开头，以 } 结尾
    BAD_LINES=$(grep -cvE '^\{.*\}$' "$JSONL" 2>/dev/null || true)
    if [ "$BAD_LINES" -eq 0 ]; then
        echo "  ✓ 所有 $(wc -l < "$JSONL") 行格式基本正确（无 jq，使用正则验证）"
    else
        echo "  ⚠ 发现 $BAD_LINES 行格式异常"
    fi
fi

# ------- 测试 3：event 字段存在 -------
echo ""
echo "[JSONL] 测试 3：event 字段存在"
EVENT_COUNT=$(grep -o '"event":"[^"]*"' "$JSONL" | wc -l)
echo "  包含 event 字段的日志行: $EVENT_COUNT"
if [ "$EVENT_COUNT" -ge 5 ]; then
    echo "  ✓ 包含足够数量的 event 字段"
else
    echo "  ✗ event 字段数量不足: $EVENT_COUNT"
    FAILED=1
fi

# 列出所有 event 类型
echo "  event 类型分布:"
grep -o '"event":"[^"]*"' "$JSONL" | sort | uniq -c | sort -rn | head -10

# ------- 测试 4：time_ms 字段合法 -------
echo ""
echo "[JSONL] 测试 4：time_ms 字段为正整数"
TIME_COUNT=$(grep -o '"time_ms":[0-9]*' "$JSONL" | wc -l)
echo "  包含 time_ms 字段的日志行: $TIME_COUNT"
if [ "$TIME_COUNT" -ge 5 ]; then
    echo "  ✓ time_ms 字段数量充足"
else
    echo "  ✗ time_ms 字段数量不足: $TIME_COUNT"
    FAILED=1
fi

# 验证 time_ms 值为正整数
BAD_TIME=$(grep -o '"time_ms":[0-9]*' "$JSONL" | grep -cvE '"time_ms":[0-9]+' || true)
if [ "$BAD_TIME" -eq 0 ]; then
    echo "  ✓ 所有 time_ms 值格式正确"
else
    echo "  ✗ 发现 $BAD_TIME 个无效 time_ms 值"
    FAILED=1
fi

# ------- 测试 5：event 类型覆盖 -------
echo ""
echo "[JSONL] 测试 5：event 类型覆盖完整性"
REQUIRED_EVENTS="worker_add worker_remove dispatch complete"
MISSING=""
for evt in $REQUIRED_EVENTS; do
    if grep -q "\"event\":\"$evt\"" "$JSONL"; then
        echo "  ✓ 包含 event: $evt"
    else
        echo "  ✗ 缺少 event: $evt"
        MISSING="$MISSING $evt"
        FAILED=1
    fi
done

# ------- 测试 6：dispatch 日志格式 -------
echo ""
echo "[JSONL] 测试 6：dispatch 日志格式"
DISPATCH_LINE=$(grep '"event":"dispatch"' "$JSONL" | head -1)
if [ -n "$DISPATCH_LINE" ]; then
    echo "  示例: $DISPATCH_LINE"
    if echo "$DISPATCH_LINE" | jq -e '.seq and .type and .target_pid' >/dev/null 2>&1; then
        echo "  ✓ dispatch 日志包含 seq、type、target_pid 字段"
    else
        echo "  ✗ dispatch 日志缺少必要字段"
        FAILED=1
    fi
else
    echo "  ⚠ 未找到 dispatch 日志（运行时间过短）"
fi

# ------- 测试 7：complete 日志格式 -------
echo ""
echo "[JSONL] 测试 7：complete 日志格式"
COMPLETE_LINE=$(grep '"event":"complete"' "$JSONL" | head -1)
if [ -n "$COMPLETE_LINE" ]; then
    echo "  示例: $COMPLETE_LINE"
    if echo "$COMPLETE_LINE" | jq -e '.seq and .type and .latency_ms' >/dev/null 2>&1; then
        echo "  ✓ complete 日志包含 seq、type、latency_ms 字段"
    else
        echo "  ✗ complete 日志缺少必要字段"
        FAILED=1
    fi
else
    echo "  ⚠ 未找到 complete 日志（运行时间过短）"
fi

# ------- 清理 -------
rm -f "$OUT"
# 保留最后一个 jsonl 文件用于检查

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ JSONL 结构化日志测试全部通过"
else
    echo "❌ JSONL 结构化日志测试有失败项"
    exit 1
fi
