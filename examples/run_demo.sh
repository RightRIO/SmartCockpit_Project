#!/bin/bash
# run_demo.sh — VoYah Scheduler quick demo
# Usage: ./examples/run_demo.sh [N]
#   N   Number of Workers (default: 5, range: 3-10)

set -e

N=${1:-5}

if ! command -v ./bin/scheduler &>/dev/null; then
    echo "[Demo] Binary not found, building first..."
    make
fi

if [[ "$N" -lt 3 ]] || [[ "$N" -gt 10 ]]; then
    echo "[Demo] Error: N must be between 3 and 10 (got: $N)"
    exit 1
fi

echo "========================================="
echo " VoYah Scheduler — Quick Demo (N=$N)"
echo "========================================="
echo "Demo will run for 15 seconds then exit."
echo "Try: + to add a Worker, s to print stats."
echo "========================================="

# Run for 15 seconds then exit
timeout 15 ./bin/scheduler "$N" || true

echo "[Demo] Done."
