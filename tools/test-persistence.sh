#!/bin/bash
# Tests cloud/save.sh and cloud/restore.sh against a local rclone remote (no Drive, no network). Run as root.
# Checks that documents round-trip, and that Chrome's profile only ever leaves the machine encrypted.
R=$(cd "$(dirname "$0")/../cloud" && pwd); T=$(mktemp -d); trap "rm -rf $T" EXIT; mkdir -p $T/drive $T/ccrd; cd $T
T=$(pwd)
export RCLONE_CONFIG=$T/rclone.conf CCRD_DIR=$T/ccrd SAVE_LOG=$T/save.log
rclone config create gdrive alias remote=$T/drive >/dev/null
mk(){ h=$1; mkdir -p $h/Documents $h/.claude-desktop-chrome/Default/Cache $h/.claude-desktop-chrome/Default/GPUCache
  echo "my letter" > $h/Documents/letter.txt
  echo "SECRET-COOKIE-MARKER" > $h/.claude-desktop-chrome/Default/Cookies
  echo "SECRET-LOGIN-MARKER" > "$h/.claude-desktop-chrome/Default/Login Data"
  echo junk > $h/.claude-desktop-chrome/Default/Cache/f_000001; echo junk > $h/.claude-desktop-chrome/Default/GPUCache/data_0
  ln -sf host-123 $h/.claude-desktop-chrome/SingletonLock; chown -R nobody:nogroup $h; }
pass=0; fail=0; ok(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
mk $T/home
echo "== 1. save without a vault password"
DESK_HOME=$T/home bash $R/save.sh
ok "documents saved" "[ -f $T/drive/claude-desktop/home/Documents/letter.txt ]"
ok "no Chrome profile anywhere in Drive" "! grep -rq SECRET $T/drive"
ok "log says profile skipped" "grep -q 'Chrome profile skipped: no vault password' $T/save.log"
echo "== 2. a vault: that is not encrypted is refused"
rclone config create vault alias remote=$T/drive/plain >/dev/null
DESK_HOME=$T/home bash $R/save.sh
ok "plain vault refused" "! grep -rq SECRET $T/drive"
rclone config delete vault
echo "== 3. save with a vault password"
rclone config create vault crypt remote=gdrive:claude-desktop-vault filename_encryption=standard directory_name_encryption=true password=$(echo test-password-123 | rclone obscure -) --no-obscure >/dev/null
DESK_HOME=$T/home bash $R/save.sh
ok "vault has files" "[ \$(find $T/drive/claude-desktop-vault -type f | wc -l) -ge 2 ]"
ok "no plaintext secrets or names in Drive" "! grep -rq SECRET $T/drive && ! find $T/drive | grep -q -e Cookies -e 'Login Data'"
ok "caches and locks left out" "! rclone lsf -R vault:chrome | grep -q -e Cache -e Singleton"
ok "log says saved encrypted" "grep -q 'saved Chrome profile (encrypted)' $T/save.log"
echo "== 4. restore on a fresh machine"
mkdir -p $T/home2; chown nobody:nogroup $T/home2; rm -f $T/ccrd/restored
DESK_HOME=$T/home2 bash $R/restore.sh; echo "exit $?"
ok "documents back" "grep -q 'my letter' $T/home2/Documents/letter.txt"
ok "logins back" "grep -q SECRET-COOKIE-MARKER $T/home2/.claude-desktop-chrome/Default/Cookies && grep -q SECRET-LOGIN-MARKER '$T/home2/.claude-desktop-chrome/Default/Login Data'"
ok "profile private (700)" "[ \$(stat -c %a $T/home2/.claude-desktop-chrome) = 700 ]"
ok "owned by the desktop user" "[ \$(stat -c %U $T/home2/.claude-desktop-chrome/Default/Cookies) = nobody ]"
ok "restored marker" "[ -f $T/ccrd/restored ]"
echo "== 5. restore never replaces newer local files"
echo "newer local" > $T/home2/Documents/letter.txt; touch -d '+1 hour' $T/home2/Documents/letter.txt
DESK_HOME=$T/home2 bash $R/restore.sh
ok "newer local kept" "grep -q 'newer local' $T/home2/Documents/letter.txt"
echo "== 6. restore without a vault password restores files only"
rclone config delete vault; mkdir -p $T/home3; chown nobody:nogroup $T/home3
DESK_HOME=$T/home3 bash $R/restore.sh
ok "files back, no profile" "[ -f $T/home3/Documents/letter.txt ] && [ ! -d $T/home3/.claude-desktop-chrome ]"
ok "log says profile not restored" "grep -q 'Chrome profile not restored: no vault password' $T/save.log"
echo "== 7. a failed Chrome restore never lets a save replace the saved logins"
rclone config create vault crypt remote=gdrive:claude-desktop-vault filename_encryption=standard directory_name_encryption=true password=$(echo test-password-123 | rclone obscure -) --no-obscure >/dev/null
mkdir -p $T/home4; chown nobody:nogroup $T/home4; rm -f $T/ccrd/restored $T/ccrd/chrome-restored $T/ccrd/last-vault-save
touch $T/home4/.claude-desktop-chrome                       # a file where the profile folder goes: the copy fails
DESK_HOME=$T/home4 bash $R/restore.sh
ok "files still marked restored" "[ -f $T/ccrd/restored ]"
ok "Chrome not marked restored" "[ ! -f $T/ccrd/chrome-restored ]"
rm -f $T/home4/.claude-desktop-chrome; mkdir -p $T/home4/.claude-desktop-chrome/Default
echo FRESH-EMPTY-PROFILE > "$T/home4/.claude-desktop-chrome/Default/Login Data"; chown -R nobody:nogroup $T/home4
# The vault can't be read during this save (Drive hiccup): an rclone that fails only for the vault listing.
mkdir -p $T/bin; printf '#!/bin/bash\n[ "$1 $2" = "lsf vault:chrome" ] && { echo "network unreachable" >&2; exit 1; }\nexec %s "$@"\n' "$(command -v rclone)" > $T/bin/rclone; chmod +x $T/bin/rclone
PATH=$T/bin:$PATH DESK_HOME=$T/home4 bash $R/save.sh
ok "save paused the profile upload" "grep -q 'saved logins not restored on this machine yet' $T/save.log"
ok "saved logins intact in the vault" "rclone cat 'vault:chrome/Default/Login Data' | grep -q SECRET-LOGIN-MARKER"
echo "== 8. the next save restores the logins first, then saves"
DESK_HOME=$T/home4 bash $R/save.sh
ok "Chrome marked restored" "[ -f $T/ccrd/chrome-restored ]"
ok "vault still has the real logins" "rclone cat 'vault:chrome/Default/Login Data' | grep -q -e SECRET-LOGIN-MARKER -e FRESH-EMPTY-PROFILE"
echo "== 9. a machine without Drive yet tries the restore before giving up"
mkdir -p $T/home5; rm -f $T/ccrd/restored; mv $T/rclone.conf $T/rclone.conf.away; touch $T/rclone.conf
DESK_HOME=$T/home5 bash $R/save.sh
ok "restore was attempted" "tail -3 $T/save.log | grep -q 'restore: no Drive sign-in available'"
mv $T/rclone.conf.away $T/rclone.conf
echo "== 10. a Chrome database copied mid-write is never uploaded"
python3 -c "import sqlite3; c=sqlite3.connect('$T/home4/.claude-desktop-chrome/Default/Web Data'); c.execute('create table t(x)'); c.executemany('insert into t values(?)', [('row%d'%i*50,) for i in range(2000)]); c.commit()"
DESK_HOME=$T/home4 bash $R/save.sh
ok "a healthy database is saved" "rclone lsf -R vault:chrome | grep -q 'Web Data'"
before=$(rclone md5sum 'vault:chrome/Default/Web Data' 2>/dev/null)
dd if=/dev/urandom of="$T/home4/.claude-desktop-chrome/Default/Web Data" bs=1 count=4096 seek=8192 conv=notrunc 2>/dev/null
DESK_HOME=$T/home4 bash $R/save.sh
ok "a damaged copy is skipped" "grep -q 'database was mid-write' $T/save.log"
ok "the last good backup is kept" "[ \"\$(rclone md5sum 'vault:chrome/Default/Web Data' 2>/dev/null)\" = \"$before\" ]"
echo "passed $pass, failed $fail"; echo "--- log"; cat $T/save.log
[ $fail = 0 ]
