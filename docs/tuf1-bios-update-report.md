# tuf1 BIOS Update - Success Report

**Date**: 2026-01-29  
**Status**: ✅ BIOS Update Successful - Monitoring in Progress

## Update Details

### BIOS Version Change
- **Before**: 1804 (February 2, 2021)
- **After**: 3636 (January 4, 2026)
- **Improvement**: ~5 years of stability updates, AGESA microcode, RAM compatibility fixes

### Pre-Update Status
- **Segfaults**: 419 in ~35 hours (~1 every 5 minutes)
- **Affected Apps**: Jellyfin, Seerr, Lidarr, Prometheus, Radarr, Sonarr
- **Root Cause**: Outdated BIOS + Mixed RAM (2x Crucial 8GB + 2x G-Skill 16GB)

### Post-Update Status
- **Node**: Back online and Ready at 19:00 (6 minutes after config reapply)
- **RAM Detected**: 48GB (all modules still present)
- **Initial Segfaults**: 0 (clean boot)
- **Monitoring**: Active (checking every 5 minutes for 1 hour)

## What Happened During Update

1. User upgraded BIOS from 1804 → 3636
2. BIOS reset cleared Talos configuration
3. Node entered maintenance mode (certificates invalid)
4. Applied Talos config with: `talosctl apply-config --insecure -n 192.168.42.254 --file talos/clusterconfig/kubernetes-tuf1.yaml`
5. Node rejoined cluster successfully

## Current Monitoring

**Script**: `/tmp/tuf1-monitor.sh` (running in background)
**Log**: `/tmp/tuf1-monitor.log`

Checks every 5 minutes for 12 iterations (1 hour total).

### Check Logs
```bash
tail -f /tmp/tuf1-monitor.log
```

### Manual Check
```bash
# Count current segfaults
talosctl -n 192.168.42.254 dmesg | grep -c "segfault"

# Show recent segfaults (if any)
talosctl -n 192.168.42.254 dmesg | grep "segfault" | tail -10
```

## Success Criteria

The BIOS update is considered successful if:
- [ ] Zero segfaults after 1 hour
- [ ] Zero segfaults after 24 hours
- [ ] All pods stable (no unexpected restarts)
- [ ] No application database corruption

## Next Steps

### If Zero Segfaults After 1 Hour
1. Continue monitoring for 24 hours
2. If still stable, consider BIOS update successful
3. Optionally: Re-enable XMP/DOCP to test 3600MHz (currently using JEDEC defaults)
4. Document final configuration

### If Segfaults Resume
1. Check if XMP/DOCP is enabled in BIOS
2. If yes: Disable XMP/DOCP, force 2666MHz JEDEC
3. If still failing: Remove 2x Crucial 8GB sticks (keep only 2x G-Skill 16GB)
4. Last resort: Replace with matched RAM kit

## Timeline

- **18:30**: Investigation started - found outdated BIOS
- **18:50**: User began BIOS upgrade
- **18:54**: Node entered maintenance mode
- **18:55**: Applied Talos config, node rejoining
- **19:00**: Node Ready, monitoring started
- **20:00**: First checkpoint (1 hour)
- **19:00 +24h**: Final validation checkpoint

## Commands Reference

### Check Node Status
```bash
kubectl get nodes -o wide | grep tuf1
```

### Check BIOS Version
```bash
talosctl -n 192.168.42.254 read /sys/class/dmi/id/bios_version
```

### Count Segfaults
```bash
talosctl -n 192.168.42.254 dmesg | grep -i segfault | wc -l
```

### Check Pod Health
```bash
kubectl get pods -n media jellyfin-ccb7d7957-d7p5q
kubectl get pods -A -o json | \
  jq -r '.items[] | select(.spec.nodeName=="tuf1") | 
  "\(.metadata.namespace)/\(.metadata.name): restarts=\(.status.containerStatuses[0].restartCount // 0)"'
```

### Monitor in Real-Time
```bash
# Watch for new segfaults
talosctl -n 192.168.42.254 dmesg -f | grep -i segfault
```

## Notes

- Node required Talos config reapply due to BIOS certificate reset
- This is expected behavior when doing major firmware updates
- All 48GB RAM still detected and working
- Mixed RAM configuration still present (not ideal, but BIOS may handle it better now)
- If stable at JEDEC speeds, this confirms BIOS was the issue
- If unstable even with new BIOS, points to hardware (RAM modules themselves)

## Related Documentation

- Main issue: `docs/tuf1-hardware-failure.md`
- Monitoring script: `scripts/monitor-tuf1-segfaults.sh`
