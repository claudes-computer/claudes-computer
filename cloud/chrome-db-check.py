#!/usr/bin/env python3
"""Exit 1 if any of Chrome's SQLite databases in a staged profile copy is damaged (copied while Chrome was writing
it). save.sh then keeps the previous backup instead of replacing it with a copy Chrome would throw away."""
import os, sqlite3, sys

root = sys.argv[1]
for dirpath, _, files in os.walk(root):
    for name in files:
        p = os.path.join(dirpath, name)
        try:
            with open(p, "rb") as f:
                if f.read(16) != b"SQLite format 3\x00":
                    continue
            con = sqlite3.connect("file:%s?mode=ro&immutable=1" % p, uri=True)
            ok = con.execute("PRAGMA quick_check").fetchone()[0] == "ok"
            con.close()
        except Exception:
            ok = False
        if not ok:
            print("damaged: %s" % os.path.relpath(p, root), file=sys.stderr)
            sys.exit(1)
