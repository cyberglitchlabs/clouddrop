# tuf1 Recovery - Next Actions Guide

**Current Status**: 20 minutes post-BIOS update, zero segfaults, system stable ✅  
**Last Updated**: Thu Jan 29 19:20 CST 2026

## Monitoring Schedule

### Automated Checks (In Progress)
Background monitor running every 5 minutes for 1 hour (12 total checks)

| Checkpoint | Time (CST) | Status | Action |
|-----------|------------|--------|--------|
| 5 min | 19:15 | ✅ PASSED | 0 segfaults |
| 10 min | 19:20 | ✅ PASSED | 0 segfaults |
| 15 min | 19:25 | 🔄 Pending | Auto-check |
| 20 min | 19:30 | 🔄 Pending | Auto-check |
| 25 min | 19:35 | 🔄 Pending | Auto-check |
| **30 min** | **19:40** | 🔄 **Pending** | **Manual validation recommended** |
| 35 min | 19:45 | 🔄 Pending | Auto-check |
| 40 min | 19:50 | 🔄 Pending | Auto-check |
| 45 min | 19:55 | 🔄 Pending | Auto-check |
| 50 min | 20:00 | 🔄 Pending | Auto-check |
| 55 min | 20:05 | 🔄 Pending | Auto-check |
| **60 min** | **20:10** | 🔄 **Pending** | **Manual validation required** |

### Key Milestones

**30-Minute Checkpoint (19:40 CST)** - Critical validation window
- Old failure rate would show 6+ segfaults by now
- If still at 0, confidence increases to 95%

**1-Hour Checkpoint (20:10 CST)** - Major stability milestone
- Old failure rate would show 12+ segfaults by now
- If still at 0, confidence increases to 98%
- Document as "highly likely resolved"

**24-Hour Checkpoint (Tomorrow 19:10 CST)** - Final validation
- Confirms long-term stability
- Confidence increases to 99.9%
- Proceed with database repair and close incident

## What to Check at Each Milestone

### 30-Minute Checkpoint (19:40 CST)

**Quick Check**:
```bash
# View monitoring log
tail /tmp/tuf1-monitor.log

# Should show checks 1-6 all with "Still 0 segfaults"
```

**If All Clear** (0 segfaults):
- ✅ Update confidence to 95%
- ✅ Continue monitoring to 1-hour mark
- ✅ No action needed

**If Segfaults Appear**:
- ⚠️ Run immediate diagnostics (see Troubleshooting section)
- ⚠️ Prepare for BIOS tuning or RAM replacement

### 1-Hour Checkpoint (20:10 CST)

**Comprehensive Check**:
```bash
# 1. Check final monitoring log
cat /tmp/tuf1-monitor.log

# 2. Verify segfault count
talosctl -n 192.168.42.254 dmesg | grep -c "segfault"

# 3. Check all pods on tuf1
kubectl get pods -A --field-selector spec.nodeName=tuf1

# 4. Check Jellyfin specifically
kubectl get pod -n media -l app.kubernetes.io/name=jellyfin -o wide
kubectl logs -n media -l app.kubernetes.io/name=jellyfin --tail=50

# 5. Check for any memory errors
talosctl -n 192.168.42.254 dmesg | grep -iE "mce|ecc|memory.*error" | tail -20

# 6. Check system events
kubectl get events -A --sort-by='.lastTimestamp' | grep -i warning | tail -20
```

**If All Clear** (0 segfaults):
- ✅ Update confidence to 98%
- ✅ Document as "preliminary success"
- ✅ Set 24-hour reminder
- ✅ Plan Jellyfin database repair

**If Segfaults Appear**:
- ⚠️ Execute contingency plan (see below)

### 24-Hour Checkpoint (Tomorrow 19:10 CST)

**Final Validation**:
```bash
# 1. Check segfault count (should still be 0)
talosctl -n 192.168.42.254 dmesg | grep -c "segfault"

# 2. Check node uptime
talosctl -n 192.168.42.254 read /proc/uptime

# 3. Check all application restarts
kubectl get pods -A --field-selector spec.nodeName=tuf1 \
  -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp

# 4. Check Jellyfin logs for any corruption errors
kubectl logs -n media -l app.kubernetes.io/name=jellyfin --tail=200 | grep -iE "corrupt|error|fail"
```

**If All Clear** (0 segfaults, no restarts):
- ✅ Close incident as **RESOLVED**
- ✅ Update documentation with final status
- ✅ Proceed with Jellyfin database repair
- ✅ Archive monitoring logs

## Contingency Plans

### If Segfaults Resume (Within 24 Hours)

**Immediate Actions**:
1. Document exact timing:
   ```bash
   talosctl -n 192.168.42.254 dmesg | grep "segfault" | tail -20
   ```

2. Check failure rate:
   ```bash
   # Count segfaults in last 5 minutes
   talosctl -n 192.168.42.254 dmesg | grep "segfault" | tail -20 | wc -l
   ```

3. Cordon node to prevent new pod assignments:
   ```bash
   kubectl cordon tuf1
   ```

**Option A: BIOS Tuning (Try First)**
1. Reboot into BIOS: `talosctl -n 192.168.42.254 reboot`
2. Disable XMP/DOCP profile (force RAM to 2666MHz JEDEC)
3. Apply config: `talosctl apply-config --insecure -n 192.168.42.254 --file talos/clusterconfig/kubernetes-tuf1.yaml`
4. Monitor for another hour

**Option B: Physical RAM Replacement (If Tuning Fails)**
1. Shutdown node: `talosctl -n 192.168.42.254 shutdown`
2. Remove 2x Crucial 8GB sticks (keep 2x G-Skill 16GB = 32GB)
3. Boot and apply config
4. Monitor for stability

**Option C: Full RAM Replacement (Last Resort)**
1. Order matched RAM kit (2x16GB or 2x32GB)
2. Shutdown node
3. Replace all RAM with matched kit
4. Boot and validate

### If Node Becomes Unresponsive

**Recovery Steps**:
```bash
# 1. Check node status
kubectl get nodes

# 2. Check cluster connectivity
talosctl -n 192.168.42.254 version

# 3. If unresponsive, force reboot
talosctl -n 192.168.42.254 reboot --mode=force

# 4. Apply config after reboot
talosctl apply-config --insecure -n 192.168.42.254 \
  --file talos/clusterconfig/kubernetes-tuf1.yaml

# 5. Wait for cluster rejoin
kubectl wait --for=condition=Ready node/tuf1 --timeout=300s
```

## Post-Validation Tasks (After 24h Stability)

### 1. Fix Jellyfin Database Corruption

**The Issue**: Old memory corruption wrote `'2013-01-01 00800:00'` instead of `'2013-01-01 00:00:00'`

**Option A: Direct SQLite Fix (Recommended)**
```bash
# 1. Access Jellyfin pod
POD=$(kubectl get pod -n media -l app.kubernetes.io/name=jellyfin -o name)
kubectl exec -it -n media $POD -- /bin/bash

# 2. Navigate to database
cd /config/data

# 3. Backup database first
cp library.db library.db.backup.$(date +%Y%m%d)

# 4. Fix corrupted datetime
sqlite3 library.db <<EOF
-- Find corrupted entries
SELECT Id, Name, PremiereDate FROM MediaItems WHERE PremiereDate LIKE '%00800:%';

-- Fix corruption (adjust WHERE clause based on above query)
UPDATE MediaItems 
SET PremiereDate = '2013-01-01 00:00:00' 
WHERE PremiereDate = '2013-01-01 00800:00';

-- Verify fix
SELECT Id, Name, PremiereDate FROM MediaItems WHERE PremiereDate LIKE '%2013-01-01%';
EOF

# 5. Restart Jellyfin to reload
kubectl rollout restart deployment -n media jellyfin
```

**Option B: Restore from Backup (If Available)**
```bash
# If you have a pre-corruption backup
kubectl exec -it -n media $POD -- /bin/bash
cd /config/data
mv library.db library.db.corrupted
cp /path/to/backup/library.db .
chown jellyfin:jellyfin library.db
exit

kubectl rollout restart deployment -n media jellyfin
```

**Verification**:
```bash
# Check Jellyfin logs for successful startup
kubectl logs -n media -l app.kubernetes.io/name=jellyfin --tail=50

# Test in browser - should load without errors
```

### 2. Update Cluster Documentation

**Add to cluster docs**:
- Minimum BIOS versions for ASUS TUF GAMING motherboards
- BIOS update procedure for Talos nodes
- Memory compatibility requirements for AMD Ryzen 5000

**Files to update**:
- `docs/hardware-requirements.md` (create if doesn't exist)
- `docs/maintenance-procedures.md` (add BIOS update section)
- `docs/tuf1-hardware-failure.md` (add resolution summary)

### 3. Consider Preventive BIOS Updates

**buzzy Node** (192.168.42.252):
- Current BIOS: 2207 (unknown date)
- Action: Check manufacturer site for updates
- Priority: Medium (no issues observed, but preventive maintenance)

**skully Node** (192.168.42.253):
- Current BIOS: 1407 (unknown date)
- Action: Check manufacturer site for updates
- Priority: Medium (no issues observed, but preventive maintenance)

**Process** (only after tuf1 fully validated):
1. Check current BIOS version: `talosctl -n <node-ip> read /sys/class/dmi/id/bios_version`
2. Check manufacturer site for latest stable version
3. If >1 year outdated, schedule maintenance window
4. Follow same procedure as tuf1 (backup, update, apply config, monitor)

### 4. Close Incident

**Final Documentation Update**:
```bash
# Update main failure doc with resolution
vi docs/tuf1-hardware-failure.md
# Add "Resolution" section with:
# - BIOS update details
# - Monitoring results
# - Final status: RESOLVED

# Archive monitoring logs
mkdir -p docs/incidents/tuf1-memory-failure-2026-01
cp /tmp/tuf1-monitor.log docs/incidents/tuf1-memory-failure-2026-01/
cp docs/tuf1-*.md docs/incidents/tuf1-memory-failure-2026-01/

# Commit documentation
git add docs/
git commit -m "docs: close tuf1 memory failure incident - resolved via BIOS update"
git push
```

## Quick Reference Commands

### Check Current Status
```bash
# Segfault count
talosctl -n 192.168.42.254 dmesg | grep -c "segfault"

# Monitoring log
tail /tmp/tuf1-monitor.log

# Pod health
kubectl get pods -A --field-selector spec.nodeName=tuf1

# Jellyfin status
kubectl get pod -n media -l app.kubernetes.io/name=jellyfin -o wide
```

### Emergency Commands
```bash
# Cordon node (prevent new pods)
kubectl cordon tuf1

# Drain node (migrate pods)
kubectl drain tuf1 --ignore-daemonsets --delete-emptydir-data

# Uncordon node (re-enable)
kubectl uncordon tuf1

# Force reboot
talosctl -n 192.168.42.254 reboot --mode=force

# Shutdown
talosctl -n 192.168.42.254 shutdown
```

## Success Criteria

### 1-Hour Validation (20:10 CST)
- ✅ Zero segmentation faults
- ✅ All pods running without restarts
- ✅ No memory-related errors in dmesg
- ✅ No application corruption events
- ✅ Clean system event log

### 24-Hour Validation (Tomorrow 19:10 CST)
- ✅ Zero segmentation faults over entire period
- ✅ No unexpected application restarts
- ✅ No new database corruption
- ✅ System logs clean
- ✅ Node uptime stable

### Resolution Complete
- ✅ 24-hour validation passed
- ✅ Jellyfin database repaired
- ✅ Documentation updated
- ✅ Incident closed
- ✅ Preventive measures documented

## Timeline Reference

| Time | Event | Status |
|------|-------|--------|
| 18:50 | BIOS update started (1804 → 3636) | ✅ Complete |
| 18:54 | Node entered maintenance mode | ✅ Complete |
| 18:55 | Talos config applied | ✅ Complete |
| 19:00 | Node rejoined cluster | ✅ Complete |
| 19:10 | Monitoring started | ✅ Running |
| 19:15 | 5-min checkpoint | ✅ Passed (0 segfaults) |
| 19:20 | 20-min status | ✅ Passed (0 segfaults) |
| 19:40 | 30-min checkpoint | 🔄 Pending |
| 20:10 | 1-hour checkpoint | 🔄 Pending |
| Tomorrow 19:10 | 24-hour checkpoint | 🔄 Pending |

---

**Current Phase**: Active Monitoring (20 minutes elapsed)  
**Next Milestone**: 30-minute checkpoint at 19:40 CST  
**Expected Outcome**: Continued stability, confidence → 95%
