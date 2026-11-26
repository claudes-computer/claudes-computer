#!/bin/bash
# Exports a public copy of this repository: tracked files only, minus private/ (working notes and drafts), and fails if a scan
# finds house details or secrets. Usage: tools/make-public.sh [out-dir]   (default: out/public)
#
# The public repository must be created from this export (fresh history), never by making this repository
# public: its history contains house details.
#
# Your own house words (family names, device names, addresses, DuckDNS name...) go in a private file, one
# extended regex per line, which is never committed:  ${CCRD_PRIVATE_PATTERNS:-~/.config/ccrd/private-patterns.txt}
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); OUT=${1:-$ROOT/out/public}
PRIV=${CCRD_PRIVATE_PATTERNS:-$HOME/.config/ccrd/private-patterns.txt}

# Files that never go public.
PRIVATE=('private/*')

cd "$ROOT"
rm -rf "$OUT"; mkdir -p "$OUT"
n=0
while IFS= read -r -d '' f; do
  skip=0; for p in "${PRIVATE[@]}"; do [[ $f == $p ]] && skip=1; done
  [ $skip = 1 ] && continue
  [ -e "$f" ] || continue
  mkdir -p "$OUT/$(dirname "$f")"; cp -p "$f" "$OUT/$f"; n=$((n+1))
done < <(git ls-files -z)
echo "exported $n files to $OUT"

# Scan. Each rule: name|regex (extended, case-insensitive). Allowed matches are filtered out below.
RULES=(
  "home network address|\\b192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}\\b|\\b192\\.168\\.[0-9]{1,3}\\.0/[0-9]+"
  "tailnet device address|\\b100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}\\b"
  "DuckDNS name|\\b[a-z0-9-]+\\.duckdns\\.org\\b"
  "tailnet name|\\b[a-z0-9-]+\\.ts\\.net\\b"
  "email address|\\b[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}\\b"
  "private key|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "Anthropic key|sk-ant-[a-z0-9_-]{10,}"
  "GitHub token|\\b(ghp|gho|ghu|ghs|github_pat)_[a-z0-9_]{20,}"
  "Tailscale key|tskey-[a-z0-9-]{10,}"
  "Google key|AIza[0-9a-z_-]{30,}"
  "AWS key|\\bAKIA[0-9A-Z]{16}\\b"
  "Slack token|xox[abpr]-[0-9a-z-]{10,}"
  "rclone token|\"access[_]token\"|refresh[_]token"
  "password assignment|(password|passwd|secret|token)[[:space:]]*[:=][[:space:]]*['\"][^'\"\$<{]{6,}['\"]"
)
# Matches that are fine in public (placeholders, project addresses, licenses).
ALLOW='www\.duckdns\.org|add-password=|noreply@anthropic\.com|@example\.(com|org)|you@|user@host|<[a-z-]+>\.(duckdns\.org|ts\.net)|example\.duckdns\.org|\*\.ts\.net|ccrd\.[a-z0-9-]*\.?ts\.net|your-tailnet|tailnet-name|login\.tailscale\.com|\.git@|git@github\.com|192\.168\.0\.0/16|192\.168\.1\.[0-9]+|100\.64\.0\.0/10|100\.100\.100\.100|password="\$OBS"|KS_PASS|LICENSE:3:Copyright \(c\) 2026 Drew$|README\.md:[0-9]+:Drew, with \[Claude Code\]'
found=0
scan(){ # name regex
  local hits
  # THIRD_PARTY_NOTICES / notices.txt are other projects' licenses: their authors' names and emails belong there.
  hits=$(grep -rIniE --exclude=THIRD_PARTY_NOTICES.txt --exclude=notices.txt -- "$2" "$OUT" 2>/dev/null | grep -viE -- "$ALLOW" || true)
  # binary files (images, etc.): look inside them too
  hits+=$'\n'$(grep -rlaiE --include="*.png" --include="*.jpg" --include="*.gif" --include="*.pdf" -- "$2" "$OUT" 2>/dev/null | sed 's/$/: (inside a binary file)/' || true)
  hits=$(printf '%s\n' "$hits" | sed '/^$/d')
  if [ -n "$hits" ]; then echo "FOUND $1:"; echo "$hits" | sed "s|$OUT/||" | head -20; found=1; fi
}
for r in "${RULES[@]}"; do scan "${r%%|*}" "${r#*|}"; done
if [ -f "$PRIV" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] || [[ $pat == \#* ]] && continue
    scan "private word" "$pat"
  done < "$PRIV"
else
  echo "note: no private word list at $PRIV (family names, device names...); only generic checks ran"
fi
# Pictures must carry no hidden metadata (camera, location, names).
if command -v python3 >/dev/null; then
  python3 - "$OUT" <<'PY' || found=1
import sys, os
try:
    from PIL import Image
except ImportError:
    sys.exit(0)
bad = 0
for d, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        if f.lower().endswith(('.jpg', '.jpeg', '.png')):
            p = os.path.join(d, f)
            try:
                im = Image.open(p); ex = im.getexif()
                text = {k: v for k, v in (im.info or {}).items() if k.lower() in ('author', 'comment', 'description', 'copyright', 'software', 'title')
                        and not str(v).lstrip("b'").startswith('Lavc')}  # ffmpeg's encoder tag is harmless
                if len(ex) or text:
                    print(f"FOUND picture metadata: {os.path.relpath(p, sys.argv[1])} exif={len(ex)} {list(text)}"); bad = 1
            except Exception:
                pass
sys.exit(bad)
PY
fi
if [ $found = 1 ]; then echo "make-public: FAILED, fix the findings above (or extend ALLOW for a placeholder)"; exit 1; fi
echo "make-public: clean"
echo "reminder: commits show their author's email. Commit the public copy as the project's public address"
echo "  (git config user.email drew@thecardiffgroup.us), squashed to one commit so no older history goes public."
