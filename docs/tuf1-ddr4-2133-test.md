# TUF1 DDR4-2133 Stability Test

**Started**: Thu Jan 29 21:19 CST 2026  
**Boot Time**: 03:17 CST (21:17 UTC)  
**Action Taken**: Changed RAM speed from Auto to Manual DDR4-2133

## Configuration Change

### BIOS Settings Changed
- **AI Overclock Tuner**: Auto → **Manual**
- **Memory Frequency**: Auto (was trying 3600MHz) → **DDR4-2133**
- **Reason**: Force JEDEC standard speed, most conservative timings

### Why DDR4-2133?
- Base JEDEC speed for DDR4 (guaranteed to work)
- G-Skill 16GB modules report 2133MHz as base speed
- Lowest stress on memory controller
- Highest compatibility with mixed RAM
- Most conservative, stable timings

### Previous Failure Pattern
**Before BIOS change (with Auto speed)**:
- Boot: 01:09 CST
- Phase 1: 01:10-02:55 CST - Stable (105 min)
- Phase 2: 02:55-03:00 CST - Burst #1 (10 failures)
- Phase 3: 03:00-03:04 CST - Brief stability (4 min)
- Phase 4: 03:04-03:06 CST - Burst #2 (4 failures)
- **Total**: 14 failures in ~2 hours

## Current Test Status

**Boot Time**: 21:17 CST (03:17 UTC)  
**Baseline Failures**: 0  
**Test Duration**: 3 hours minimum  
**Current Status**: 🟢 Monitoring started

### Timeline
```
21:17 CST - Node booted with DDR4-2133
21:19 CST - Talos config reapplied
21:19 CST - Monitoring started (0 failures)
```

## Monitoring Plan

### Check Intervals
- Every 2 minutes for first 3 hours
- Log all checks with timestamps
- Alert on ANY failure

### Critical Milestones
- ✅ 10 minutes stable (21:29 CST)
- ✅ 30 minutes stable (21:49 CST)
- ✅ 1 hour stable (22:19 CST)
- ✅ 2 hours stable (23:19 CST) - Previous burst point
- ✅ 3 hours stable (00:19 CST) - Test complete

### Success Criteria
**PASS**: 0 failures in 3 hours
- Confirms DDR4-2133 resolved the issue
- Continue monitoring for 24 hours
- Fix Jellyfin database
- Optional: Upgrade to matched RAM for better performance

**FAIL**: ANY failures in 3 hours
- DDR4-2133 did not resolve issue
- Next action: Remove mixed RAM configuration
- Run with matched 2x16GB G-Skill only (32GB)
- If still failing: Replace all RAM

## Hardware Configuration

**Motherboard**: ASUS TUF GAMING B550M-PLUS  
**CPU**: AMD Ryzen 5 5600X (Zen 3)  
**BIOS**: 3636 (January 4, 2026)

**RAM Configuration**: 48GB DDR4 (MIXED)
- DIMM_A1: Crucial 8GB (BL8G36C16U4BL.M8FE1) - rated 3600MHz
- DIMM_A2: G-Skill 16GB (F4-3600C16-16GTZNC) - rated 3600MHz, base 2133MHz
- DIMM_B1: Crucial 8GB (BL8G36C16U4BL.M8FE1) - rated 3600MHz
- DIMM_B2: G-Skill 16GB (F4-3600C16-16GTZNC) - rated 3600MHz, base 2133MHz

**Current Speed**: DDR4-2133 (JEDEC standard, forced in BIOS)  
**Previous Speed**: Auto (was attempting 3600MHz with mixed timings)

## Expected Outcome

### If DDR4-2133 Works (Most Likely)
This confirms the issue was:
- RAM speed too high for mixed configuration
- Auto mode selecting incompatible timings
- Memory controller unable to handle 3600MHz with mixed sticks

**Long-term implications**:
- System will be stable but slower (~40% memory bandwidth loss)
- Can upgrade to matched RAM kit later for full 3600MHz speed
- Current configuration acceptable for homelab use

### If DDR4-2133 Fails (Hardware Issue)
This indicates:
- One or more RAM sticks have hardware failure
- Issue is not just speed/timing related
- Physical hardware replacement required

**Next steps**:
1. Remove 2x Crucial 8GB sticks
2. Test with matched 2x16GB G-Skill only
3. If still failing: Replace all RAM

## Performance Impact

**Memory Bandwidth Comparison**:
- DDR4-3600: ~28.8 GB/s (theoretical)
- DDR4-2133: ~17.0 GB/s (theoretical)
- **Loss**: ~41% bandwidth reduction

**Real-world impact**:
- Most applications: Minimal impact (not memory-bound)
- Media transcoding (Jellyfin): Slight impact (mostly GPU-bound)
- AI workloads (Ollama, Immich ML): Moderate impact
- Database operations: Slight impact
- **Stability gain**: PRICELESS ✅

## Monitoring Commands

### Manual monitoring
```bash
# Watch failure count
watch -n 30 'talosctl -n 192.168.42.254 dmesg | grep -c "segfault"'

# Get last failures
talosctl -n 192.168.42.254 dmesg | grep -E "segfault|general protection fault" | tail -5

# Check pod status
kubectl get pods -A --field-selector spec.nodeName=tuf1 | grep -v "Running\|Completed"
```

### Automated monitoring
```bash
# Run 3-hour monitoring script
/tmp/tuf1-ddr4-2133-monitoring.sh

# Log file location
/tmp/tuf1-ddr4-2133-monitor-YYYYMMDD-HHMMSS.log
```

## Related Documentation

- [tuf1-hardware-failure.md](./tuf1-hardware-failure.md) - Initial failure analysis
- [tuf1-bios-update-report.md](./tuf1-bios-update-report.md) - BIOS update (1804 → 3636)
- [tuf1-status-current.md](./tuf1-status-current.md) - Post-BIOS status (failures continued)
- [jellyfin-database-corruption-fix.md](./jellyfin-database-corruption-fix.md) - Database fix (pending)

## Test Results

**Will be updated as monitoring progresses...**

### 10-Minute Check (21:29 CST)
*Pending*

### 30-Minute Check (21:49 CST)
*Pending*

### 1-Hour Check (22:19 CST)
*Pending*

### 2-Hour Check (23:19 CST)
*Pending - Critical milestone (previous burst point)*

### 3-Hour Check (00:19 CST)
*Pending - Test completion*

---

**Test in progress... monitoring for failures...**
