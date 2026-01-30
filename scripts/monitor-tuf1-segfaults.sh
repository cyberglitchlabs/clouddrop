#!/usr/bin/env bash
# Monitor tuf1 for segmentation faults after BIOS update
# Usage: ./monitor-tuf1-segfaults.sh

set -euo pipefail

NODE_IP="192.168.42.254"
CHECK_INTERVAL=300  # 5 minutes

echo "=== tuf1 Segfault Monitor ==="
echo "Node: ${NODE_IP}"
echo "Checking every ${CHECK_INTERVAL} seconds (5 minutes)"
echo ""

# Get initial count
INITIAL_COUNT=$(talosctl -n "${NODE_IP}" dmesg 2>/dev/null | grep -c "segfault" || echo "0")
echo "Initial segfault count: ${INITIAL_COUNT}"
echo "Started monitoring at: $(date)"
echo "---"

# Monitor loop
PREVIOUS_COUNT="${INITIAL_COUNT}"
while true; do
    sleep "${CHECK_INTERVAL}"
    
    CURRENT_COUNT=$(talosctl -n "${NODE_IP}" dmesg 2>/dev/null | grep -c "segfault" || echo "0")
    NEW_SEGFAULTS=$((CURRENT_COUNT - PREVIOUS_COUNT))
    
    if [ "${NEW_SEGFAULTS}" -gt 0 ]; then
        echo "⚠️  [$(date)] NEW SEGFAULTS DETECTED: +${NEW_SEGFAULTS} (total: ${CURRENT_COUNT})"
        # Show last 5 segfaults
        echo "Recent segfaults:"
        talosctl -n "${NODE_IP}" dmesg 2>/dev/null | grep "segfault" | tail -5
        echo "---"
    else
        echo "✅ [$(date)] No new segfaults (total: ${CURRENT_COUNT})"
    fi
    
    PREVIOUS_COUNT="${CURRENT_COUNT}"
done
