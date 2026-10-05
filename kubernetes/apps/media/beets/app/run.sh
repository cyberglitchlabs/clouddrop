#!/bin/sh
# MODE=import  : match + record in /state/library.db, NO file writes (-W)       [trial step 1]
# MODE=preview : `beet write -p` shows exact tag diffs, writes nothing           [trial step 2]
# MODE=apply   : `beet write` for TARGET_PATH only                               [trial step 3]
# MODE=nightly : import with write:yes for every eligible album dir under TARGET_PATH
# Never calls move/update/mbsync/modify/remove. No file or folder is renamed or deleted.
set -e
[ -n "$MODE" ] && [ -n "$TARGET_PATH" ] || { echo "MODE and TARGET_PATH are required"; exit 2; }
[ -n "$MIN_AGE_MIN" ] || MIN_AGE_MIN=120   # skip album dirs with any file modified in the last N minutes
export BEETSDIR=/etc/beets HOME=/tmp PYTHONPATH=/tools
beet() { python -m beets -c /etc/beets/config.yaml "$@"; }
exec 9>/state/beets.lock
flock -n 9 || { echo "another beets run holds the lock; exiting"; exit 0; }
echo "$(date -Is) mode=$MODE target=$TARGET_PATH beets=$(beet version | head -1)"
case "$MODE" in
  preview) beet write -p "path:$TARGET_PATH"; exit 0 ;;
  apply)   beet write "path:$TARGET_PATH"; exit 0 ;;
esac
# eligible album dirs: contain audio, and NO audio file touched within MIN_AGE_MIN
find "$TARGET_PATH" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.opus' -o -iname '*.ogg' \) -printf '%h\n' | sort -u > /tmp/all.txt
find "$TARGET_PATH" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.opus' -o -iname '*.ogg' \) -mmin "-$MIN_AGE_MIN" -printf '%h\n' | sort -u > /tmp/recent.txt
grep -vxFf /tmp/recent.txt /tmp/all.txt > /tmp/eligible.txt || true
echo "album dirs: $(wc -l </tmp/all.txt) total, $(wc -l </tmp/recent.txt) skipped as recently modified, $(wc -l </tmp/eligible.txt) eligible"
FLAGS="-q -C -M"; [ "$MODE" = import ] && FLAGS="$FLAGS -W"
tr '\n' '\0' </tmp/eligible.txt | xargs -0 -r -n 20 python -m beets -c /etc/beets/config.yaml import $FLAGS
echo "$(date -Is) done"
