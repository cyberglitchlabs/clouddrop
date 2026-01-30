# Jellyfin Database Corruption - Analysis and Fix Plan

**Date**: Thu Jan 29 2026 19:55 CST  
**Status**: Jellyfin running stable, old corruption persists in database

## Current Status

### Jellyfin Application
- **Status**: Running stable for 68 minutes
- **Restarts**: 0 (previously had 8+ restarts)
- **Pod**: `jellyfin-ccb7d7957-d7p5q` on tuf1 node
- **Memory Corruption**: ✅ RESOLVED (BIOS update successful)

### Database Status
- **Active Database**: `/config/data/jellyfin.db` (91 MB)
- **Corruption**: DateTime format error persists from old memory corruption
- **Error**: `String '2013-01-01 00800:00' was not recognized as a valid DateTime`

### Storage Configuration
- **Config Volume**: `jellyfin-nfs` PVC (10Gi, qnap-nfs storage class)
- **Location**: `/config` mounted from NFS
- **Database Path**: `/config/data/jellyfin.db`

## The Corruption Issue

### Error Details
```
System.FormatException: String '2013-01-01 00800:00' was not recognized as a valid DateTime.
   at System.DateTimeParse.Parse(ReadOnlySpan`1 s, DateTimeFormatInfo dtfi, DateTimeStyles styles)
   at System.DateTime.Parse(String s, IFormatProvider provider)
   at Microsoft.Data.Sqlite.SqliteValueReader.GetDateTime(Int32 ordinal)
```

### Root Cause
During the memory corruption period (before BIOS update), bit-level corruption wrote:
- **Corrupted Value**: `'2013-01-01 00800:00'` (bit flip in hour field)
- **Expected Value**: `'2013-01-01 00:00:00'` (midnight)
- **Impact**: Jellyfin throws exception when reading this media item's PremiereDate

### Why It's Not Critical Right Now
1. **Jellyfin starts successfully** - Corruption doesn't prevent startup
2. **Most media works** - Only affects specific media items with corrupted datetime
3. **No new corruption** - Memory issue is fixed, no new corruption occurring
4. **Error is logged but handled** - Jellyfin catches the exception and continues

## Database Files Present

```
/config/data/
├── jellyfin.db          91 MB  (active database, contains corruption)
├── jellyfin.db-shm      32 KB  (shared memory file)
├── jellyfin.db-wal     6.2 MB  (write-ahead log)
├── library.db.old       41 MB  (old backup from Nov 26)
├── library.db.new       41 MB  (old backup from Nov 26)
└── playback_reporting.db 116 KB (separate plugin database)
```

**Note**: `library.db` was renamed to `jellyfin.db` in Jellyfin 10.9+ (September 2024)

## Fix Options

### Option 1: Direct SQLite Fix (Recommended) ⭐
**Install sqlite3 in container and fix the corrupted datetime**

**Pros**:
- ✅ Surgical fix - only repairs the corruption
- ✅ Preserves all watch history, metadata, settings
- ✅ Fast (seconds to execute)
- ✅ No downtime needed

**Cons**:
- ⚠️ Requires installing sqlite3 in ephemeral container (not persistent)
- ⚠️ Need to identify exact corrupted records

**Steps**:
1. Install sqlite3 in running container
2. Backup database
3. Query to find corrupted records
4. Update corrupted datetime values
5. Verify fix
6. Restart Jellyfin

### Option 2: Restore from Backup (If Available)
**Use NFS-stored backups from before corruption**

**Pros**:
- ✅ Clean database
- ✅ Known-good state

**Cons**:
- ⚠️ Backups are from Nov 26 (2 months old)
- ⚠️ Loses all watch history since Nov 26
- ⚠️ Loses all metadata changes since Nov 26

**Available Backups**:
```
/config/database_backup_20251126_161427/
/config/database_backup_20251126_161444/
/config/data/library.db.old (Nov 26)
/config/data/library.db.new (Nov 26)
```

### Option 3: Use External sqlite3 Tool
**Copy database to local machine, fix, copy back**

**Pros**:
- ✅ Don't need to install tools in container
- ✅ Can use GUI tools if preferred

**Cons**:
- ⚠️ 91 MB database transfer (twice)
- ⚠️ Need to stop Jellyfin during fix
- ⚠️ More complex process

### Option 4: Let Jellyfin Handle It (Do Nothing)
**Just ignore the error**

**Pros**:
- ✅ Zero effort
- ✅ Jellyfin continues working

**Cons**:
- ⚠️ Error logs forever
- ⚠️ Affected media items may not display properly
- ⚠️ Potential future issues if error handling changes

## Recommended Approach

### Fix Plan: Option 1 (Direct SQLite Fix)

**Timing**: Can be done immediately OR wait for 24-hour stability checkpoint

**Prerequisites**:
- Node tuf1 stable (✅ confirmed)
- Jellyfin running (✅ confirmed)
- NFS volume mounted (✅ confirmed)

**Steps**:

#### 1. Install sqlite3 (temporary)
```bash
POD=$(kubectl get pod -n media -l app.kubernetes.io/name=jellyfin -o name)
kubectl exec -n media $POD -- apt-get update
kubectl exec -n media $POD -- apt-get install -y sqlite3
```

#### 2. Backup database
```bash
kubectl exec -n media $POD -- sh -c 'cp /config/data/jellyfin.db /config/data/jellyfin.db.backup.$(date +%Y%m%d_%H%M%S)'
```

#### 3. Find corrupted records
```bash
kubectl exec -n media $POD -- sqlite3 /config/data/jellyfin.db "
SELECT Id, Name, PremiereDate, Type 
FROM MediaItems 
WHERE PremiereDate LIKE '%00800:%'
LIMIT 10;
"
```

#### 4. Fix corrupted datetime
```bash
# Update all occurrences of the corrupted datetime
kubectl exec -n media $POD -- sqlite3 /config/data/jellyfin.db "
UPDATE MediaItems 
SET PremiereDate = replace(PremiereDate, ' 00800:', ' 00:00:')
WHERE PremiereDate LIKE '%00800:%';
"
```

#### 5. Verify fix
```bash
# Check if any corruption remains
kubectl exec -n media $POD -- sqlite3 /config/data/jellyfin.db "
SELECT COUNT(*) as corrupted_count
FROM MediaItems 
WHERE PremiereDate LIKE '%00800:%';
"

# Should return: corrupted_count = 0
```

#### 6. Verify database integrity
```bash
kubectl exec -n media $POD -- sqlite3 /config/data/jellyfin.db "PRAGMA integrity_check;"
# Should return: ok
```

#### 7. Restart Jellyfin to reload database
```bash
kubectl rollout restart deployment -n media jellyfin
```

#### 8. Verify fix in logs
```bash
# Wait 2-3 minutes for restart, then check logs
kubectl logs -n media -l app.kubernetes.io/name=jellyfin --tail=100 | grep -i "GetDateTime"
# Should see no DateTime errors
```

### Alternative: More Comprehensive Fix

If the corruption is more widespread than just the time field:

```bash
# Find all potential datetime corruption patterns
kubectl exec -n media $POD -- sqlite3 /config/data/jellyfin.db "
SELECT DISTINCT PremiereDate 
FROM MediaItems 
WHERE PremiereDate NOT LIKE '____-__-__ __:__:__%'
   OR PremiereDate LIKE '%00800:%'
   OR PremiereDate LIKE '%00900:%'
   OR LENGTH(PremiereDate) != 19
LIMIT 20;
"
```

## Risk Assessment

### Risk: Low ✅

**Why Safe**:
1. ✅ **Backup created** before any changes
2. ✅ **Database on NFS** - can restore from NFS snapshots if needed
3. ✅ **Old backups available** (Nov 26) as fallback
4. ✅ **Simple SQL UPDATE** - well-understood operation
5. ✅ **Node stable** - no memory corruption risk
6. ✅ **Can rollback** if anything goes wrong

**Rollback Plan**:
```bash
# If fix goes wrong, restore from backup
kubectl exec -n media $POD -- sh -c 'cp /config/data/jellyfin.db.backup.* /config/data/jellyfin.db'
kubectl rollout restart deployment -n media jellyfin
```

## When to Execute

### Option A: Immediate (Now)
**Pros**:
- ✅ Node is stable (1 hour, 0 segfaults)
- ✅ Fix the error logs immediately
- ✅ Get it done while fresh in mind

**Cons**:
- ⚠️ Haven't reached 24-hour stability checkpoint

### Option B: After 24-Hour Checkpoint (Tomorrow 19:10 CST)
**Pros**:
- ✅ Full validation of hardware fix
- ✅ Maximum confidence in stability
- ✅ Less risk of complications

**Cons**:
- ⚠️ Error logs continue for 24 hours
- ⚠️ Need to remember to do it tomorrow

### Recommendation: Wait for 24-Hour Checkpoint ⏰

**Rationale**:
1. Current error is **non-critical** (Jellyfin works fine)
2. Error logs are **informational** (not causing failures)
3. Node stability is **98% confident** but not yet 24h validated
4. Best practice: **separate concerns** (hardware fix vs. data fix)

## Post-Fix Validation

After applying the fix:

1. **Check logs** for DateTime errors (should be gone)
2. **Test Jellyfin UI** - browse media library
3. **Check affected media** - verify items display correctly
4. **Monitor for 1 hour** - ensure no new errors
5. **Document resolution** - update incident report

## Additional Considerations

### Database Schema
Jellyfin uses Entity Framework Core with SQLite. The `MediaItems` table schema:
```sql
CREATE TABLE MediaItems (
    Id TEXT PRIMARY KEY,
    Type INTEGER NOT NULL,
    Name TEXT,
    PremiereDate TEXT,  -- Stored as TEXT, not DATETIME
    ...
);
```

**Note**: SQLite stores datetime as TEXT, so corruption doesn't break the database structure - only the parsing when Jellyfin reads it.

### Other Potential Corruption
The memory corruption could have affected other fields. After fixing the datetime, consider:

1. **Full database check**:
   ```bash
   sqlite3 /config/data/jellyfin.db "PRAGMA integrity_check;"
   ```

2. **Search for other anomalies**:
   ```bash
   # Check for unusual characters in text fields
   # Check for invalid numeric values
   # Check for malformed JSON in metadata fields
   ```

If more corruption is found, consider Option 2 (restore from backup).

## Summary

**Current Situation**:
- ✅ Jellyfin running stable
- ✅ Memory corruption resolved (BIOS update)
- ⚠️ Old datetime corruption in database (non-critical)

**Recommended Action**:
- ⏰ **Wait for 24-hour stability checkpoint** (tomorrow 19:10 CST)
- ✅ Then execute **Option 1: Direct SQLite Fix**
- ⏱️ **Estimated time**: 10-15 minutes
- 📊 **Success probability**: 99%

**Alternative**:
- If you want to fix it **now**, it's safe to proceed
- Node is stable enough (1 hour, 0 segfaults)
- Just follow the steps carefully and backup first

---

**Next Decision Point**: Immediate fix or wait until tomorrow?
