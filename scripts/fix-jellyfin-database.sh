#!/usr/bin/env bash
set -euo pipefail

# Jellyfin Database Corruption Fix Script
# Fixes datetime corruption from memory failure: '2013-01-01 00800:00' -> '2013-01-01 00:00:00'

echo "=== Jellyfin Database Corruption Fix ==="
echo "Date: $(date)"
echo ""

# Configuration
NAMESPACE="media"
LABEL="app.kubernetes.io/name=jellyfin"
DB_PATH="/config/data/jellyfin.db"

# Get pod name
echo "Finding Jellyfin pod..."
POD=$(kubectl get pod -n "$NAMESPACE" -l "$LABEL" -o name)
if [ -z "$POD" ]; then
    echo "ERROR: Jellyfin pod not found"
    exit 1
fi
echo "Pod: $POD"
echo ""

# Check if pod is running
STATUS=$(kubectl get -n "$NAMESPACE" "$POD" -o jsonpath='{.status.phase}')
if [ "$STATUS" != "Running" ]; then
    echo "ERROR: Pod is not running (status: $STATUS)"
    exit 1
fi
echo "Pod status: Running ✅"
echo ""

# Step 1: Install sqlite3
echo "=== Step 1: Installing sqlite3 in container ==="
echo "This is temporary and will be lost on pod restart"
kubectl exec -n "$NAMESPACE" "$POD" -- apt-get update -qq
kubectl exec -n "$NAMESPACE" "$POD" -- apt-get install -y -qq sqlite3
echo "sqlite3 installed ✅"
echo ""

# Step 2: Backup database
echo "=== Step 2: Creating backup ==="
BACKUP_NAME="jellyfin.db.backup.$(date +%Y%m%d_%H%M%S)"
kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "cp $DB_PATH /config/data/$BACKUP_NAME"
echo "Backup created: /config/data/$BACKUP_NAME ✅"
echo ""

# Step 3: Check database integrity BEFORE fix
echo "=== Step 3: Checking database integrity (pre-fix) ==="
INTEGRITY=$(kubectl exec -n "$NAMESPACE" "$POD" -- sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1 | head -1)
if [ "$INTEGRITY" = "ok" ]; then
    echo "Database integrity: OK ✅"
else
    echo "WARNING: Database integrity check returned: $INTEGRITY"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi
fi
echo ""

# Step 4: Find corrupted records
echo "=== Step 4: Finding corrupted records ==="
echo "Looking for datetime values with '00800:' pattern..."
CORRUPTED_COUNT=$(kubectl exec -n "$NAMESPACE" "$POD" -- sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM MediaItems WHERE PremiereDate LIKE '%00800:%';" 2>&1)
echo "Found $CORRUPTED_COUNT corrupted record(s)"

if [ "$CORRUPTED_COUNT" -gt 0 ]; then
    echo ""
    echo "Sample corrupted records:"
    kubectl exec -n "$NAMESPACE" "$POD" -- sqlite3 "$DB_PATH" \
        "SELECT Id, Name, PremiereDate, Type FROM MediaItems WHERE PremiereDate LIKE '%00800:%' LIMIT 5;" \
        2>&1 || echo "Could not retrieve sample records"
fi
echo ""

# Step 5: Fix corrupted datetime
if [ "$CORRUPTED_COUNT" -gt 0 ]; then
    echo "=== Step 5: Fixing corrupted datetime values ==="
    read -p "Proceed with fix? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting. Backup is available at: /config/data/$BACKUP_NAME"
        exit 1
    fi

    kubectl exec -n "$NAMESPACE" "$POD" -- sqlite3 "$DB_PATH" \
        "UPDATE MediaItems SET PremiereDate = replace(PremiereDate, ' 00800:', ' 00:00:') WHERE PremiereDate LIKE '%00800:%';"
    
    echo "Fix applied ✅"
    echo ""
else
    echo "No corrupted records found - nothing to fix!"
    echo ""
fi

# Step 6: Verify fix
echo "=== Step 6: Verifying fix ==="
REMAINING_COUNT=$(kubectl exec -n "$NAMESPACE" "$POD" -- sqlite3 "$DB_PATH" \
    "SELECT COUNT(*) FROM MediaItems WHERE PremiereDate LIKE '%00800:%';" 2>&1)
echo "Remaining corrupted records: $REMAINING_COUNT"

if [ "$REMAINING_COUNT" -eq 0 ]; then
    echo "All corruption fixed ✅"
else
    echo "WARNING: $REMAINING_COUNT records still corrupted"
fi
echo ""

# Step 7: Check database integrity AFTER fix
echo "=== Step 7: Checking database integrity (post-fix) ==="
INTEGRITY_POST=$(kubectl exec -n "$NAMESPACE" "$POD" -- sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1 | head -1)
if [ "$INTEGRITY_POST" = "ok" ]; then
    echo "Database integrity: OK ✅"
else
    echo "ERROR: Database integrity check failed: $INTEGRITY_POST"
    echo "Consider restoring from backup: /config/data/$BACKUP_NAME"
    exit 1
fi
echo ""

# Step 8: Restart Jellyfin
echo "=== Step 8: Restarting Jellyfin ==="
read -p "Restart Jellyfin to apply changes? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Skipping restart. You can restart manually with:"
    echo "  kubectl rollout restart deployment -n $NAMESPACE jellyfin"
    exit 0
fi

kubectl rollout restart deployment -n "$NAMESPACE" jellyfin
echo "Restart initiated ✅"
echo ""

echo "Waiting for new pod to be ready..."
kubectl wait --for=condition=ready pod -n "$NAMESPACE" -l "$LABEL" --timeout=300s
echo "New pod ready ✅"
echo ""

# Step 9: Verify fix in logs
echo "=== Step 9: Checking logs for errors ==="
sleep 10  # Give Jellyfin time to start and scan
echo "Checking for DateTime errors in logs..."
NEW_POD=$(kubectl get pod -n "$NAMESPACE" -l "$LABEL" -o name)
DATETIME_ERRORS=$(kubectl logs -n "$NAMESPACE" "$NEW_POD" --tail=200 2>&1 | grep -c "GetDateTime" || true)

if [ "$DATETIME_ERRORS" -eq 0 ]; then
    echo "No DateTime errors found in logs ✅"
else
    echo "WARNING: Found $DATETIME_ERRORS DateTime error(s) in logs"
    echo "Recent logs:"
    kubectl logs -n "$NAMESPACE" "$NEW_POD" --tail=50 | grep -A3 -B3 "GetDateTime" || true
fi
echo ""

# Summary
echo "=== Fix Complete ==="
echo "✅ Backup created: /config/data/$BACKUP_NAME"
echo "✅ Corrupted records fixed: $CORRUPTED_COUNT"
echo "✅ Database integrity: OK"
echo "✅ Jellyfin restarted"
echo ""
echo "Next steps:"
echo "1. Test Jellyfin UI - browse media library"
echo "2. Monitor logs for 1 hour: kubectl logs -n media -l app.kubernetes.io/name=jellyfin -f"
echo "3. If issues occur, restore backup:"
echo "   kubectl exec -n media \$POD -- cp /config/data/$BACKUP_NAME /config/data/jellyfin.db"
echo "   kubectl rollout restart deployment -n media jellyfin"
echo ""
echo "Backup will persist on NFS volume even after pod restarts."
