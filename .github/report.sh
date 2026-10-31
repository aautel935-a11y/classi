#!/bin/sh
# Turns the end of each log into a GitHub annotation, so results can be read from the check run itself.
job="$1"; shift
for f in "$@"; do
  [ -f "$f" ] || { echo "::notice title=$job $(basename "$f")::(not run)"; continue; }
  body=$(tail -n 45 "$f" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-220 | sed ':a;N;$!ba;s/%/%25/g;s/\r//g;s/\n/%0A/g')
  if grep -qiE "error|fail|✘|not ok" "$f"; then echo "::warning title=$job $(basename "$f")::$body"; else echo "::notice title=$job $(basename "$f")::$body"; fi
done
