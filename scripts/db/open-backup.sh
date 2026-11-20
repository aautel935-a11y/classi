#!/bin/sh
# Opens an encrypted Classi backup LATER, on the owner's computer (or in a test), from the stored file alone:
#   1. checks the file against its .sha256 (when it sits next to it)
#   2. decrypts it with the owner's private key into a NEW private folder
#   3. checks every file inside against its SHA256SUMS
#   4. prints table and row totals only (never data)
#   5. only if TARGET_URL is set: restores into that EMPTY database with restore-check.sh (row counts compared)
# Usage:  sh scripts/db/open-backup.sh <file.tar.age> <private key file> <new folder>
#         TARGET_URL='postgresql://…empty, not production…' sh scripts/db/open-backup.sh …   (restore as well)
# The key file may itself be passphrase-protected (age -p): use "-" as key file and pipe it in, e.g.
#         age -d classi-backup.key.age | sh scripts/db/open-backup.sh <file.tar.age> - <new folder>
# The folder holds personal data once opened: keep it off synced folders and delete it when done.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd -P)"
F="${1:?usage: open-backup.sh <file.tar.age> <private key file|-> <new folder>}"
KEY="${2:?usage: open-backup.sh <file.tar.age> <private key file|-> <new folder>}"
OUT="${3:?usage: open-backup.sh <file.tar.age> <private key file|-> <new folder>}"
command -v age >/dev/null 2>&1 || { echo "missing: age (https://age-encryption.org)"; exit 2; }
[ -s "$F" ] || { echo "FAIL: $F is missing or empty"; exit 1; }
[ -e "$OUT" ] && { echo "refusing: $OUT already exists (give a new folder)"; exit 2; }
if [ -s "$F.sha256" ]; then
  ( cd "$(dirname "$F")" && sha256sum -c --quiet "$(basename "$F").sha256" ) || { echo "FAIL: the file does not match its SHA-256 (damaged or replaced)"; exit 1; }
  echo "ok: SHA-256 matches"
else
  echo "note: no $F.sha256 next to the file; skipping that check"
fi
umask 077; mkdir -p "$OUT"
if [ "$KEY" = "-" ]; then id="$OUT/.key"; cat > "$id"; else id="$KEY"; fi
if ! age -d -i "$id" -o "$OUT/backup.tar" "$F" 2>"$OUT/.age.err"; then
  [ "$KEY" = "-" ] && rm -f "$id"; rm -f "$OUT/backup.tar"
  echo "FAIL: this key does not open the file ($(head -1 "$OUT/.age.err" | sed 's/^age: //'))"; rm -f "$OUT/.age.err"; exit 1
fi
[ "$KEY" = "-" ] && rm -f "$id"; rm -f "$OUT/.age.err"
tar -C "$OUT" -xf "$OUT/backup.tar"; rm -f "$OUT/backup.tar"
B=$(ls -d "$OUT"/classi-backup-* 2>/dev/null | head -1)
[ -n "$B" ] || { echo "FAIL: no backup folder inside the file"; exit 1; }
( cd "$B" && sha256sum -c --quiet SHA256SUMS ) || { echo "FAIL: a file inside does not match SHA256SUMS"; exit 1; }
echo "ok: opened, every file matches SHA256SUMS: $(wc -l < "$B/counts.txt") tables, $(awk -F'|' '{s+=$2} END {print s+0}' "$B/counts.txt") rows -> $B"
if [ -n "${TARGET_URL:-}" ]; then
  sh "$HERE/restore-check.sh" "$B"
fi
