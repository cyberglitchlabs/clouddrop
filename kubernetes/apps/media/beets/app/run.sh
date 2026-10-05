#!/bin/sh
# MODE=import  : match + record in /state/library.db, NO file writes (-W)       [trial step 1]
# MODE=preview : `beet write -p` shows exact tag diffs, writes nothing           [trial step 2]
# MODE=apply   : `beet write` for TARGET_PATH only                               [trial step 3]
# MODE=diag    : verbose match report, no incremental, NO writes                 [why was an album skipped?]
# MODE=nightly : import with write:yes for every eligible album dir under TARGET_PATH
# Never calls move/update/mbsync/modify/remove. No file or folder is renamed or deleted.
set -e
set -f   # no glob expansion of the -iname patterns
[ -n "$MODE" ] && [ -n "$TARGET_PATH" ] || { echo "MODE and TARGET_PATH are required"; exit 2; }
[ -n "$MIN_AGE_MIN" ] || MIN_AGE_MIN=120   # skip album dirs with any file modified in the last N minutes
[ -n "$MUSIC_ROOT" ] || MUSIC_ROOT=/media/Music
export BEETSDIR=/etc/beets HOME=/tmp PYTHONPATH=/tools
beet() { python -m beets -c /etc/beets/config.yaml "$@"; }
exec 9>/state/beets.lock
flock -n 9 || { echo "another beets run holds the lock; exiting"; exit 0; }
echo "$(date -Is) mode=$MODE target=$TARGET_PATH beets=$(beet version | head -1)"
case "$MODE" in
  preview) beet write -p "path:$TARGET_PATH"; exit 0 ;;
  apply)   beet write "path:$TARGET_PATH"; exit 0 ;;
esac
AUDIO="-iname *.flac -o -iname *.mp3 -o -iname *.m4a -o -iname *.opus -o -iname *.ogg"
# Album dir = Artist/Album (2 levels under MUSIC_ROOT) so multi-disc subfolders (CD 01/CD 02) stay one album.
to_album() { awk -v root="$MUSIC_ROOT" 'BEGIN{n=length(root)} index($0,root"/")==1 {rel=substr($0,n+2); k=split(rel,p,"/"); if(k>=2) print root"/"p[1]"/"p[2]; else print $0; next} {print $0}' | sort -u; }
find "$TARGET_PATH" -type f \( $AUDIO \) -printf '%h\n' | to_album > /tmp/all.txt
find "$TARGET_PATH" -type f \( $AUDIO \) -mmin "-$MIN_AGE_MIN" -printf '%h\n' | to_album > /tmp/recent.txt
grep -vxFf /tmp/recent.txt /tmp/all.txt > /tmp/eligible.txt || true
echo "album dirs: $(wc -l </tmp/all.txt) total, $(wc -l </tmp/recent.txt) skipped as recently modified, $(wc -l </tmp/eligible.txt) eligible"
case "$MODE" in
  diag)    FLAGS="-q -C -M -W -I" ; CMD="python -m beets -vv -c /etc/beets/config.yaml import" ;;
  import)  FLAGS="-q -C -M -W" ;     CMD="python -m beets -c /etc/beets/config.yaml import" ;;
  nightly) FLAGS="-q -C -M" ;        CMD="python -m beets -c /etc/beets/config.yaml import" ;;
  *) echo "unknown MODE $MODE"; exit 2 ;;
esac
tr '\n' '\0' </tmp/eligible.txt | xargs -0 -r -n 20 $CMD $FLAGS
echo "$(date -Is) done"
