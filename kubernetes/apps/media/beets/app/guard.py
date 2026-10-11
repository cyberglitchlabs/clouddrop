#!/usr/bin/env python3
"""beets-tag nightly driver: records new albums, guards them, writes tags in place. Never moves/copies/deletes.

Called by run.sh (MODE=seed|nightly|nightly-dry) after run.sh has built /tmp/eligible.txt (album dirs whose
files are all older than MIN_AGE_MIN). Flow:
  1. `beet import -q -C -M -W` on eligible dirs: matches and records in the library DB, writes NOTHING.
  2. Candidate albums = library album ids not yet in /state/seen-album-ids.txt (so only albums first seen this run;
     albums handled by the manual passes, held albums and anything SoulSync retagged later are never rewritten).
  3. Per candidate: `beet write -p album_id:N` (preview), guard it, `beet write album_id:N` only if clean.
  4. Held albums go to /logs/beets-held.tsv with the reason; they are not retried (retag by hand if wanted).
"""
import os, re, sys, subprocess, time, unicodedata, difflib

ROOT = os.environ.get("MUSIC_ROOT", "/media/Music")
CFG = "/etc/beets/config.yaml"
SEEN = "/state/seen-album-ids.txt"
HELD = "/logs/beets-held.tsv"
ELIGIBLE = "/tmp/eligible.txt"
MAX_TITLE_ARTIST_PCT = 5.0


def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    s = re.sub(r"\bthe\b", " ", s)
    return re.sub(r"\s+", " ", s).strip()


SEP = re.compile(r"\s*(?:&|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bx\b|\bvs\.?|,|;|/|\band\b)\s*", re.I)


def acts(s):
    return {a for a in (norm(x) for x in SEP.split(s or "")) if a}


def judge(artist, old, new_list, new_str):
    """None if the album-artist change is allowed, else a reason."""
    a = norm(artist)
    nold, nnew = norm(old), norm(new_str)
    if nold == nnew:
        return None
    if difflib.SequenceMatcher(None, nold, nnew).ratio() >= 0.9:
        return None  # case/spelling variant
    new_acts = {norm(x) for x in new_list} if new_list else acts(new_str)
    old_acts = acts(old)
    if nnew == "various artists":
        return "album artist would become Various Artists"
    if not old_acts or nold == "various artists":
        ok = len(new_acts) == 1 and all(
            x == a or a in x or x in a or difflib.SequenceMatcher(None, x, a).ratio() >= 0.9 for x in new_acts)
        return None if ok else "empty/VA -> acts not just the main act: %s" % sorted(new_acts)
    if new_acts <= old_acts:
        return None  # collaboration credit -> main act
    extra = {e for e in new_acts - old_acts
             if not any(difflib.SequenceMatcher(None, e, o).ratio() >= 0.85 for o in old_acts)}
    return None if not extra else "new acts not in old: %s" % sorted(extra)


def parse_preview(txt):
    items, cur = [], None
    for line in txt.split("\n"):
        if line.startswith(ROOT + "/"):
            cur = [line, []]
            items.append(cur)
        elif cur is not None and line.startswith(" ") and line.strip():
            cur[1].append(line)
    return items


def violations(artist, items):
    """(list of (item, old, new, reason), pct of items changing title AND to an unrelated artist)."""
    bad, title_art = [], 0
    for t, ls in items:
        old = new = None
        new_list, in_aa = [], False
        has_title = any(re.match(r"^  title:.*->", l) for l in ls)
        art_unrel = False
        for l in ls:
            m = re.match(r"^  albumartist:\s*(.*?)\s*->\s*(.*)$", l)
            if m:
                old, new = m.group(1), m.group(2)
                in_aa = False
                continue
            if re.match(r"^  albumartists:\s*$", l):
                in_aa = True
                continue
            if in_aa:
                m2 = re.match(r"^    \+ (.*)$", l)
                if m2:
                    new_list.append(m2.group(1))
                    continue
                if not l.startswith("    "):
                    in_aa = False
            m3 = re.match(r"^  artist:\s*(.*?)\s*->\s*(.*)$", l)
            if m3:
                x, y = m3.group(1), m3.group(2)
                na = norm(artist)
                if not (na in norm(y) or norm(y) in na or acts(x) & acts(y)):
                    art_unrel = True
        if has_title and art_unrel:
            title_art += 1
        if new is not None:
            r = judge(artist, old, new_list, new)
            if r:
                bad.append((t, old, new, r))
    pct = round(100.0 * title_art / max(1, len(items)), 1)
    return bad, pct


def album_dir(path):
    rel = path[len(ROOT) + 1:] if path.startswith(ROOT + "/") else path
    return "/".join(rel.split("/")[:2])


def beet(*args, check=True):
    p = subprocess.run([sys.executable, "-m", "beets", "-c", CFG] + list(args),
                       capture_output=True, text=True)
    if check and p.returncode != 0:
        print("beet %s failed (%d): %s" % (" ".join(args[:2]), p.returncode, p.stderr[-500:]))
    return p.returncode, p.stdout, p.stderr


def library():
    """album id -> set(Artist/Album dirs)."""
    _, out, _ = beet("ls", "-f", "$album_id|$path")
    lib = {}
    for line in out.split("\n"):
        i, _, p = line.partition("|")
        if i.isdigit() and p:
            lib.setdefault(int(i), set()).add(album_dir(p))
    return lib


def load_seen():
    try:
        return {int(x) for x in open(SEEN).read().split() if x.isdigit()}
    except FileNotFoundError:
        return set()


def save_seen(ids):
    tmp = SEEN + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(str(i) for i in sorted(ids)) + "\n")
    os.replace(tmp, SEEN)


def log_held(rows):
    new_file = not os.path.exists(HELD)
    with open(HELD, "a") as f:
        if new_file:
            f.write("date\talbum_dir\told_albumartist\tnew_albumartist\treason\n")
        for r in rows:
            f.write("\t".join(r) + "\n")


def main(mode):
    if mode == "seed":
        lib = library()
        save_seen(set(lib))
        print("seeded %d existing album ids as already handled" % len(lib))
        return 0
    dry = mode == "nightly-dry"
    eligible = [l.rstrip("\n") for l in open(ELIGIBLE) if l.strip()]
    eset = set(album_dir(d) for d in eligible)
    for i in range(0, len(eligible), 20):
        print("import batch %d/%d" % (i // 20 + 1, (len(eligible) + 19) // 20))
        _, out, err = beet("import", "-q", "-C", "-M", "-W", *eligible[i:i + 20], check=False)
        if re.search(r"Traceback", err):
            print("import traceback:\n" + err[-800:])
    seen = load_seen()
    lib = library()
    cands = {i: d for i, d in lib.items() if i not in seen}
    print("library albums: %d, candidates (not yet seen): %d" % (len(lib), len(cands)))
    today = time.strftime("%Y-%m-%d")
    applied, held, handled = [], [], set()
    for i, dirs in sorted(cands.items()):
        d = sorted(dirs)[0]
        if not dirs <= eset:
            print("album %d (%s): has files outside the eligible set, retry later" % (i, d))
            continue
        artist = d.split("/")[0]
        rc, prev, err = beet("write", "-p", "album_id:%d" % i)
        if rc != 0:
            held.append([today, d, "", "", "preview failed"])
            handled.add(i)
            continue
        items = parse_preview(prev)
        bad, pct = violations(artist, items)
        reason = None
        if bad:
            reason = bad[0][3]
        elif pct > MAX_TITLE_ARTIST_PCT:
            reason = "%.1f%% of tracks change title and artist to an unrelated act" % pct
        if reason:
            o, n = (bad[0][1], bad[0][2]) if bad else ("", "")
            held.append([today, d, o or "", n or "", reason])
            handled.add(i)
            print("HOLD %s: %s" % (d, reason))
            continue
        if not items:
            print("clean %s: no tag changes" % d)
            handled.add(i)
            continue
        if dry:
            print("WOULD APPLY %s: %d files change" % (d, len(items)))
            continue
        rc, out, err = beet("write", "album_id:%d" % i)
        if rc != 0 or re.search(r"(?i)traceback|error", err):
            held.append([today, d, "", "", "write error"])
        else:
            applied.append(d)
            print("APPLIED %s: %d files" % (d, len(items)))
        handled.add(i)
    if not dry:
        if held:
            log_held(held)
        save_seen(seen | handled)
    print("summary: applied=%d held=%d dry=%s" % (len(applied), len(held), dry))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "nightly"))
