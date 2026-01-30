# TUF1 Node - Current Status Analysis

**Generated**: Thu Jan 29 21:05 CST 2026  
**Last Updated**: After BIOS update 1804 → 3636

## Executive Summary

**Status**: 🟡 **MONITORING - Burst Pattern Observed**

The BIOS update from 1804 to 3636 has **NOT fully resolved** the memory corruption issue, but has **changed the failure pattern**:

- **Pre-BIOS**: Steady ~12 failures/hour (419 failures in 35 hours)
- **Post-BIOS**: 105 minutes stable → 10 failures in 5 minutes → stable again?

**Current situation**: 4+ minutes since last failure (as of 21:05 CST)

## Timeline Since BIOS Update

### Phase 1: Initial Stability ✅
**Duration**: 01:10 - 02:55 CST (105 minutes)  
**Failures**: 0  
**Status**: Perfect stability, all pods running normally

### Phase 2: Failure Burst ❌
**Duration**: 02:55 - 03:00 CST (5 minutes)  
**Failures**: 10 total
- 8 general protection faults
- 2 segmentation faults

**Affected Applications**:
- `mealie` (Python) - general protection fault
- `sonarr` (.NET) - general protection fault → CrashLoopBackOff
- Multiple Python/gunicorn workers - segfaults and general protection faults

**Failure Rate During Burst**: ~2 failures per minute

### Phase 3: Current Status 🟢
**Duration**: 03:00 - 03:04+ CST (4+ minutes so far)  
**Failures**: 0  
**Status**: All pods recovered, Sonarr running after 3 restarts

## Failure Analysis

### Overall Statistics
- **Total runtime since boot**: ~115 minutes
- **Total failures**: 10 (all during 5-minute burst)
- **Overall failure rate**: ~5.2 failures/hour
- **Improvement vs pre-BIOS**: ~57% reduction

### Failure Breakdown
```
Segfaults:                 2
General protection faults: 8
Total:                    10
```

### Failure Timeline
```
02:55:49 - mealie (Python) - GPF
02:55:51 - python - GPF
02:57:09 - python - GPF
02:57:11 - .NET TP Worker - GPF
02:57:14 - Sonarr - GPF
02:57:49 - gunicorn worker - SEGFAULT
02:57:50 - python3 - GPF
02:57:50 - gunicorn worker - GPF
02:57:52 - python - SEGFAULT
03:00:34 - python - GPF (last failure)
```

## Critical Observations

### 1. Failures NOT Eliminated
- BIOS update improved but did NOT resolve root cause
- Memory corruption events still occurring
- Hardware instability remains

### 2. NEW Burst Pattern
- **Pre-BIOS**: Continuous steady failures (~12/hour)
- **Post-BIOS**: Long stable period → short burst → stable again?
- **Implication**: Different stability characteristics, but still unstable

### 3. All Pods Recovered
- Sonarr recovered after 3 restarts
- 22 pods on tuf1, all currently Running
- No pods in CrashLoopBackOff at time of writing

### 4. Observation Period Too Short
- Only 4 minutes since last failure
- Previous stable period was 105 minutes
- **Need 2-3 hours minimum** to confirm pattern

## Theories for Burst Pattern

### Most Likely: XMP/DOCP Re-enabled
**Probability**: HIGH

BIOS update likely re-enabled XMP/DOCP profile, forcing RAM to DDR4-3600. Mixed RAM configuration cannot handle high speeds reliably, causing intermittent failures when memory controller pushes limits.

**Action**: Disable XMP/DOCP in BIOS, force JEDEC DDR4-2666

### Thermal Issue
**Probability**: MEDIUM

- Node runs cool initially
- After ~1.5 hours, temperature reaches threshold
- Triggers memory instability for ~5 minutes
- Throttling/cooling brings back to stability

**Action**: Monitor temperatures, improve cooling

### Workload-Specific Trigger
**Probability**: MEDIUM

- Specific applications (Sonarr, Mealie, Python workers) performing operations
- Certain memory access patterns expose RAM instability
- Operations complete, returns to stable state

**Action**: Review application logs during burst window

### Memory Training Period
**Probability**: LOW

- New BIOS retraining memory timings at runtime
- Temporary instability during training
- Settled into stable timings after burst

**Action**: Monitor if burst repeats

### Intermittent Hardware Fault
**Probability**: MEDIUM

- One RAM stick failing intermittently
- Temperature or voltage dependent
- Shows up in bursts rather than continuous failures

**Action**: Test individual RAM sticks

## Current Pod Status on tuf1

**Total Pods**: 22 (all in media namespace)  
**Status**: All Running ✅

### Recent Restart History
- `sonarr`: 3 restarts (last 3m ago)
- `bazarr`: 2 restarts (last 6m ago)
- `jellystat`: 3 restarts (last 7m ago)
- `immich-server`: 4 restarts (last 7m ago)
- `radarr`: 1 restart (last 7m ago)

### Stable Pods (0 restarts)
- jellyfin, immich-machine-learning, audiobookshelf
- lidarr, prowlarr, seerr, sabnzbd
- And 13 more...

### Critical Workloads at Risk
1. **Control Plane Components** (etcd, kube-apiserver, controller-manager, scheduler)
2. **Jellyfin** - Already has database corruption
3. **Immich** - AI/photo processing with database
4. **Sonarr/Radarr/Lidarr** - Media tracking databases

## Next Actions

### Immediate (Now - Next 10 Minutes)

1. **Continue monitoring** - Watch for any new failures
   ```bash
   watch -n 30 'talosctl -n 192.168.42.254 dmesg | grep -E "segfault|general protection fault" | tail -5'
   ```

2. **Check pod status** - Ensure no new CrashLoops
   ```bash
   watch -n 30 'kubectl get pods -A --field-selector spec.nodeName=tuf1 | grep -v "Running\|Completed"'
   ```

3. **Review application logs** - Understand what triggered burst
   ```bash
   kubectl logs -n media deployment/sonarr --tail=100
   kubectl logs -n media deployment/mealie --tail=100
   ```

### Short-term (Next 2-3 Hours)

1. **Run enhanced monitoring script** (recommended)
   ```bash
   /tmp/tuf1-enhanced-monitor.sh
   ```
   - Monitors for 3 hours
   - Checks every 2 minutes
   - Alerts on new failures
   - Tracks if burst repeats at ~2-hour mark

2. **Watch for pattern** - Does burst repeat at 2-hour intervals?

3. **Document timeline** - Record any new failures with exact timestamps

### If Failures Resume (Any New Failures)

**ACTION REQUIRED**: Disable XMP/DOCP in BIOS

1. **Reboot into BIOS**:
   ```bash
   talosctl -n 192.168.42.254 reboot
   # Press DEL key repeatedly during boot
   ```

2. **Navigate to memory settings**:
   - Location: `AI Tweaker` or `Extreme Tweaker` section
   - Find: `D.O.C.P.` or `XMP` setting
   - Current value likely: `D.O.C.P. Standard` or `Enabled`

3. **Disable XMP/DOCP**:
   - Change to: `Disabled` or `Auto`
   - RAM will default to JEDEC DDR4-2666 or DDR4-2933

4. **Save and exit** (F10)

5. **Reapply Talos config**:
   ```bash
   talosctl apply-config --insecure -n 192.168.42.254 \
     --file talos/clusterconfig/kubernetes-tuf1.yaml
   ```

6. **Monitor for 3+ hours** to confirm stability

### If Stable for 3+ Hours

1. **Consider running memory stress test** (optional):
   ```bash
   # Run stress test pod on tuf1
   # Monitor for failures during high memory load
   ```

2. **Document the burst pattern** - Update this file with findings

3. **Evaluate acceptability**:
   - If bursts are predictable and pods recover quickly: Maybe acceptable short-term
   - If bursts are random or increasing: NOT acceptable
   - If data corruption risk continues: NOT acceptable

4. **Still recommend XMP/DOCP disable** as preventive measure
   - Mixed RAM + XMP is never recommended
   - Even if "working", stability margin is too low

### If XMP/DOCP Disable Fails

**Proceed to hardware changes**:

1. **Remove mixed RAM configuration**:
   - Shutdown node: `talosctl -n 192.168.42.254 shutdown`
   - Remove 2x Crucial 8GB sticks (DIMM_A1, DIMM_B1)
   - Keep 2x G-Skill 16GB sticks (DIMM_A2, DIMM_B2) = 32GB matched
   - Boot and reapply config
   - Monitor for stability

2. **If still failing, replace all RAM**:
   - Order matched 2x16GB or 2x32GB DDR4-3600 kit (same brand, model)
   - Replace all RAM
   - Test for stability

## Risk Assessment

**Current Risk Level**: 🟡 MODERATE

### Acceptable Risk?
- ✅ **Short-term**: If bursts are rare (every few hours) and predictable
- ❌ **Long-term**: NOT acceptable - data corruption risk too high
- ❌ **Control Plane**: tuf1 hosts control plane components - instability is critical

### Data at Risk
1. **Jellyfin database** - Already corrupted (`00800:00` instead of `00:00:00`)
2. **Immich database** - Photo/AI metadata
3. **Sonarr/Radarr/Lidarr databases** - Media tracking and download management
4. **etcd** - Kubernetes cluster state (CRITICAL)

### Recommendation
**Disable XMP/DOCP regardless of short-term stability**

Even if the system appears stable now, the burst pattern indicates underlying instability. Mixed RAM + XMP is never recommended by AMD or motherboard manufacturers. The BIOS update improved timing margins but did not eliminate the fundamental incompatibility.

## Hardware Configuration

**Motherboard**: ASUS TUF GAMING B550M-PLUS  
**CPU**: AMD Ryzen 5 5600X (Zen 3 - sensitive to RAM compatibility)  
**BIOS**: 3636 (January 4, 2026) - **JUST UPDATED**  
**Previous BIOS**: 1804 (February 2, 2021)

**RAM Configuration**: 48GB DDR4-3600 (MIXED - ROOT CAUSE)
- DIMM_A1: Crucial 8GB (BL8G36C16U4BL.M8FE1)
- DIMM_A2: G-Skill 16GB (F4-3600C16-16GTZNC)
- DIMM_B1: Crucial 8GB (BL8G36C16U4BL.M8FE1)
- DIMM_B2: G-Skill 16GB (F4-3600C16-16GTZNC)

**Issue**: Mixed capacity (8GB + 16GB) and mixed brands
- Different timing chips
- Different ICs (integrated circuits)
- Different manufacturing tolerances
- XMP/DOCP profiles validated for matched kits ONLY

## Comparison: Other Nodes (Healthy)

**buzzy** (192.168.42.252):
- RAM: 12GB (likely matched configuration)
- BIOS: 2207
- Failures since boot: 0 ✅

**skully** (192.168.42.253):
- RAM: 16GB (likely matched configuration)
- BIOS: 1407
- Failures since boot: 0 ✅

**Conclusion**: Issue is isolated to tuf1 hardware, specifically mixed RAM configuration.

## Related Documentation

- [tuf1-hardware-failure.md](./tuf1-hardware-failure.md) - Initial failure analysis
- [tuf1-bios-update-report.md](./tuf1-bios-update-report.md) - BIOS update procedure
- [tuf1-next-actions.md](./tuf1-next-actions.md) - Action plan (needs updating)
- [jellyfin-database-corruption-fix.md](./jellyfin-database-corruption-fix.md) - Database corruption details
- [tuf1-README.md](./tuf1-README.md) - Overview (now outdated - BIOS didn't fully fix)

## Monitoring Scripts

**Enhanced 3-hour monitoring**:
```bash
/tmp/tuf1-enhanced-monitor.sh
```
- Monitors for 3 hours
- Checks every 2 minutes
- Logs to `/tmp/tuf1-monitor-YYYYMMDD-HHMMSS.log`
- Alerts on new failures
- Watches for repeat burst at 2-hour mark

**Manual monitoring**:
```bash
# Watch for new failures
watch -n 30 'talosctl -n 192.168.42.254 dmesg | grep -c "segfault"'

# Get last 5 failures
talosctl -n 192.168.42.254 dmesg | grep -E "segfault|general protection fault" | tail -5

# Check pod status
kubectl get pods -A --field-selector spec.nodeName=tuf1 | grep -v "Running\|Completed"
```

## Conclusion

The BIOS update from 1804 to 3636 has **improved but NOT resolved** the memory corruption issue on tuf1. The failure pattern has changed from continuous (~12/hour) to burst (10 in 5 minutes), but failures still occur.

**Primary recommendation**: Disable XMP/DOCP in BIOS to force JEDEC standard speeds (DDR4-2666). This is the safest first step that can be done immediately without hardware changes.

**Secondary recommendation**: If XMP/DOCP disable fails, remove mixed RAM configuration and run with matched 2x16GB G-Skill kit (32GB total).

**Tertiary recommendation**: If matched subset fails, replace all RAM with new matched kit.

**Monitor continuously** for the next 2-3 hours to determine if burst pattern repeats or if system stabilizes.
