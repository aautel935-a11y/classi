#!/bin/sh
# Run ON YOUR COMPUTER after creating the backup key, and again whenever you change BACKUP_AGE_RECIPIENTS:
# proves the public key you put in GitHub belongs to the private key you keep, so backups can be opened later.
# A typo in the public key would still encrypt, but nobody could ever open the backups.
# Usage:  sh scripts/db/check-backup-key.sh <private key file> 'age1…the value of BACKUP_AGE_RECIPIENTS…'
#         age -d classi-backup.key.age | sh scripts/db/check-backup-key.sh - 'age1…'   (passphrase-protected key)
# Prints only MATCH or NO MATCH; never prints the private key.
set -eu
KEY="${1:?usage: check-backup-key.sh <private key file|-> 'age1…'}"; PUB="${2:?usage: check-backup-key.sh <private key file|-> 'age1…'}"
command -v age-keygen >/dev/null 2>&1 || { echo "missing: age-keygen (install age: https://age-encryption.org)"; exit 2; }
PUB=$(printf %s "$PUB" | tr -d '[:space:]')
case "$PUB" in age1*) ;; AGE-SECRET-KEY*) echo "STOP: that is a PRIVATE key. Never put it in GitHub. Give the age1… public key."; exit 2;; *) echo "not an age public key (must start with age1)"; exit 2;; esac
if [ "$KEY" = "-" ]; then derived=$(age-keygen -y 2>/dev/null) || { echo "NO MATCH: could not read a private key"; exit 1; }
else derived=$(age-keygen -y "$KEY" 2>/dev/null) || { echo "NO MATCH: could not read a private key from $KEY"; exit 1; }; fi
if [ "$derived" = "$PUB" ]; then echo "MATCH: backups encrypted to this public key open with your private key"
else echo "NO MATCH: this public key does not belong to your private key; fix BACKUP_AGE_RECIPIENTS"; exit 1; fi
