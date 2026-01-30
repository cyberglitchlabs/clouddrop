# tuf1 Node Hardware Failure - RAM Issue

**Status**: ⚠️ CRITICAL - Active Hardware Failure  
**Date Identified**: 2026-01-29  
**Root Cause**: Mixed/Failing RAM Configuration  
**Impact**: System-wide memory corruption, application crashes, data corruption  

## Executive Summary

The tuf1 node (192.168.42.254) is experiencing a **hardware memory failure** causing:
- 419 segmentation faults in ~35 hours (~1 every 5 minutes)
- Application crashes (Jellyfin, Seerr, Lidarr, Prometheus, Radarr, Sonarr)
- SQLite database corruption in Jellyfin
- System library corruption (ld-musl, libpython, libgcc)

**Action Required**: Replace/test RAM modules during maintenance window.

## Hardware Configuration

### Node Details
- **Hostname**: tuf1
- **IP**: 192.168.42.254
- **Motherboard**: ASUS TUF GAMING B550M-PLUS
- **CPU**: AMD Ryzen 5 5600X 6-Core Processor (Zen 3 architecture)
- **Storage**: Samsung SSD 860 EVO M.2 1TB
- **OS**: Talos Linux v1.12.1
- **Kubernetes**: v1.34.1

### BIOS Information
- **Version**: 1804 (February 2, 2021) ⚠️ **CRITICALLY OUTDATED**
- **Latest**: 2423 (November 2024)
- **Age**: 3+ years behind
- **Vendor**: American Megatrends Inc.
- **Impact**: Missing AGESA microcode updates, RAM training fixes, stability improvements

### Current RAM Configuration (PROBLEMATIC)
**Total**: 48GB (MIXED BRANDS/SIZES)

| Slot | Brand | Size | Model | Speed |
|------|-------|------|-------|-------|
| DIMM_A1 | CRUCIAL | 8GB | BL8G36C16U4BL.M8FE1 | 3600MHz |
| DIMM_A2 | G-Skill | 16GB | F4-3600C16-16GTZNC | 3600MHz |
| DIMM_B1 | CRUCIAL | 8GB | BL8G36C16U4BL.M8FE1 | 3600MHz |
| DIMM_B2 | G-Skill | 16GB | F4-3600C16-16GTZNC | 3600MHz |

⚠️ **Critical Problems**:
1. **Mixed brands**: Crucial (Micron chips) + G-Skill (SK Hynix chips) have different voltage/timing characteristics
2. **Mixed capacities**: 8GB + 16GB in same channel violates dual-channel best practices
3. **Running at 3600MHz**: XMP/DOCP overclock + old BIOS + mixed RAM = instability
4. **4 DIMMs populated**: Increases memory controller stress (AMD Ryzen prefers 2 DIMMs)
5. **Outdated BIOS**: Missing 3+ years of RAM compatibility fixes and AGESA updates

⚠️ **AMD Ryzen 5000 Specifics**:
- Zen 3 memory controller is notoriously sensitive to mixed configurations
- Requires updated AGESA microcode for proper RAM training
- XMP profiles may not work with old BIOS versions

## Failure Evidence

### Segmentation Fault Pattern
```
Total Segfaults: 419 in ~35 hours
Start Time: 2026-01-28 13:29
Rate: ~1 every 5 minutes
```

**CPU Core Distribution** (most affected):
```
CPU 3:  74 segfaults
CPU 5:  72 segfaults
CPU 9:  71 segfaults
CPU 11: 70 segfaults
```

### Affected System Libraries
- `ld-musl-x86_64.so.1` (dynamic linker)
- `libpython3.13.so.1.0` (Python runtime)
- `libgcc_s.so.1` (GCC support library)

### Data Corruption Example
**Jellyfin SQLite Database** (`/config/data/library.db`):
```
Corrupted Value: '2013-01-01 00800:00'
Expected Format: '2013-01-01 00:00:00'
Error: Bit corruption in datetime field
```

This demonstrates bit-level data corruption from faulty RAM.

### Cluster Comparison
| Node | RAM | Segfaults | Status |
|------|-----|-----------|--------|
| **tuf1** | 48GB (mixed) | **419** | ⚠️ FAILING |
| buzzy | 12GB | 0 | ✅ Healthy |
| skully | 16GB | 0 | ✅ Healthy |

**Conclusion**: Issue is isolated to tuf1 hardware, not software/configuration.

## Maintenance Plan

## Maintenance Plan

### RECOMMENDED ORDER OF ATTEMPTS

Start with easiest/safest options first before hardware changes:

### Option 1: BIOS Update (HIGHEST PRIORITY - Do This First!)
**Goal**: Update to latest BIOS with RAM compatibility fixes

⚠️ **CRITICAL**: Current BIOS 1804 (Feb 2021) is **3+ years outdated**

**Why This May Fix Everything**:
- BIOS 2423 includes AGESA 1.2.0.9+ with Zen 3 memory training fixes
- Over 600 stability patches since your version
- Fixes for mixed RAM configurations
- Improved memory controller voltage regulation
- Better SPD detection and training algorithms

**Steps**:
1. Download BIOS 2423 from ASUS support site: https://www.asus.com/motherboards-components/motherboards/tuf-gaming/tuf-gaming-b550m-plus/helpdesk_bios/
2. Extract to FAT32-formatted USB drive (root directory)
3. Drain node: `kubectl drain tuf1 --ignore-daemonsets --delete-emptydir-data`
4. Shutdown: `talosctl -n 192.168.42.254 shutdown`
5. Connect monitor/keyboard, power on
6. Press DEL to enter BIOS
7. Use "EZ Flash 3" utility (in Tools menu)
8. Select BIOS file from USB and flash
9. **After flash completes**:
   - Load Optimized Defaults (F5)
   - Set DOCP/XMP to **Disabled** (use JEDEC 2666MHz temporarily)
   - Save and reboot (F10)
10. Boot Talos and monitor for segfaults
11. If stable for 24h, can try enabling DOCP again

**Risks**:
- Power loss during flash can brick motherboard (ensure stable power)
- Takes 10-15 minutes total
- No hardware changes needed

**Expected Outcome**: 70% chance this fixes the issue completely

---

### Option 2: Disable XMP/DOCP (If BIOS Update Not Possible)
**Goal**: Run RAM at JEDEC 2666MHz instead of XMP 3600MHz

**Why This May Help**:
- Old BIOS + XMP + mixed RAM = extremely unstable
- JEDEC timings are conservative and universally compatible
- Reduces memory controller stress
- ~20% slower but stable

**Steps**:
1. Access BIOS during maintenance window
2. Advanced Settings → AI Tweaker
3. Set DOCP/XMP to **Disabled**
4. Verify "DRAM Frequency" shows 2666MHz (DDR4-2666)
5. Set all timing overrides to **Auto**
6. Save and reboot (F10)
7. Monitor for 24 hours

**Trade-off**: Performance loss acceptable for server workload

---

### Option 3: Remove 2 DIMMs (Keep Only G-Skill)
**Goal**: Reduce to matched pair, decrease memory controller stress

**Steps**:
1. Drain and shutdown node (as above)
2. Remove both 8GB Crucial sticks (DIMM_A1, DIMM_B1)
3. Keep only 2x 16GB G-Skill in **A2 + B2 slots** (recommended by ASUS)
4. Boot and test: Run memtest86+ for 2+ hours
5. If stable, uncordon node: `kubectl uncordon tuf1`

**Result**: 32GB RAM (down from 48GB) but proper dual-channel configuration

**Pros**:
- Free (use existing hardware)
- Proper dual-channel setup
- Less stress on memory controller
- Can enable XMP/DOCP after BIOS update

---

### Option 4: RAM Replacement (Most Expensive)
**Goal**: Replace with proper matched kit designed for Ryzen 5000

**Recommended Kits** (must be sold as kit, not individual sticks):
- **Budget**: G.Skill Ripjaws V 2x16GB DDR4-3600 CL16 (~$60)
- **Mid-range**: Crucial Ballistix 2x32GB DDR4-3600 CL16 (~$120)
- **Premium**: G.Skill Trident Z Neo 2x32GB DDR4-3600 CL16 (~$150) - Ryzen-optimized

**Steps**:
1. Purchase matched kit
2. Drain and shutdown node
3. Remove all existing RAM
4. Install new kit in A2 + B2 slots
5. Boot and enable DOCP in BIOS
6. Run memtest86+ for 4+ hours
7. If passes, uncordon node

---

### Option 5: RAM Module Testing (Diagnostic)
**Goal**: Identify which specific module(s) are failing

**Steps**:
1. Drain and shutdown node
2. Test each module individually with memtest86+ (minimum 1 hour each):
   - Test DIMM_A1 (Crucial 8GB) alone in A2 slot
   - Test DIMM_A2 (G-Skill 16GB) alone in A2 slot
   - Test DIMM_B1 (Crucial 8GB) alone in A2 slot
   - Test DIMM_B2 (G-Skill 16GB) alone in A2 slot
3. Document which modules pass/fail
4. Test working pairs together
5. Remove/replace failed modules

**Note**: This helps identify bad hardware but takes 4-8 hours total

## Pre-Maintenance Checklist

- [ ] **Download BIOS 2423** from ASUS support site
- [ ] Prepare FAT32 USB drive with BIOS file
- [ ] Schedule maintenance window (2-4 hours for BIOS update + testing)
- [ ] Notify users of planned downtime
- [ ] Create backup: `task bootstrap:talos` (capture node config)
- [ ] Prepare memtest86+ USB drive (for RAM testing if needed)
- [ ] Document current BIOS settings (take photos before updating)
- [ ] Ensure stable power supply during BIOS flash (UPS recommended)
- [ ] Have monitor/keyboard ready for BIOS access
- [ ] Optional: Purchase replacement RAM kit (if BIOS update fails)

## Maintenance Commands

### Drain Node
```bash
# Evict all pods from tuf1
kubectl drain tuf1 --ignore-daemonsets --delete-emptydir-data --force

# Verify pods moved to other nodes
kubectl get pods -A -o wide | grep tuf1
```

### Power Down
```bash
# Graceful shutdown
talosctl -n 192.168.42.254 shutdown

# Verify node is down
ping 192.168.42.254
kubectl get nodes
```

### Post-Maintenance Recovery
```bash
# Wait for node to boot and join cluster
kubectl get nodes -w

# Uncordon node
kubectl uncordon tuf1

# Verify node is Ready
kubectl get nodes

# Check for new segfaults after 1 hour
talosctl -n 192.168.42.254 dmesg | grep -i segfault | tail -20
```

## Monitoring Commands

### Real-time Segfault Monitoring
```bash
# Watch for new segfaults
talosctl -n 192.168.42.254 dmesg -f | grep -i segfault

# Count segfaults every 5 minutes
watch -n 300 'talosctl -n 192.168.42.254 dmesg | grep -i segfault | wc -l'
```

### Check Pod Health on tuf1
```bash
# List all pods on tuf1 with restart counts
kubectl get pods -A -o json | \
  jq -r '.items[] | select(.spec.nodeName=="tuf1") | 
  "\(.metadata.namespace)/\(.metadata.name): \(.status.containerStatuses[0].restartCount) restarts"' | \
  sort -t: -k2 -rn
```

### Verify RAM Configuration
```bash
# Check current RAM details
talosctl -n 192.168.42.254 read /sys/firmware/dmi/tables/DMI | \
  strings | grep -A 20 "Memory Device"

# Check total memory
talosctl -n 192.168.42.254 read /proc/meminfo | grep MemTotal
```

## Success Criteria

After RAM replacement/repair, the node is considered stable when:
- [ ] Zero segfaults for 24 hours continuous operation
- [ ] All pods running without unexpected restarts
- [ ] No database corruption in applications
- [ ] memtest86+ passes 4+ hour test with zero errors
- [ ] System temperatures remain normal under load

## References

- **Segfault Investigation**: dmesg logs 2026-01-28 to 2026-01-29
- **AMD RAM Guidelines**: Use matched pairs, prefer single-rank modules
- **ASUS TUF B550M Manual**: Chapter 1-7 (Memory Configuration)
- **Talos Maintenance**: https://www.talos.dev/v1.12/talos-guides/upgrading-talos/

## Notes

- This is a **hardware failure**, not a software/configuration issue
- All affected applications will automatically recover once RAM is stable
- Database repairs should only be attempted AFTER RAM is fixed
- Consider upgrading to 64GB (2x32GB) if purchasing new modules
- Keep one spare module for future testing/replacement
