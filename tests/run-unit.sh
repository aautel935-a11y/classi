#!/bin/sh
# Unit tests for lib/*.ts. Usage (from anywhere): sh tests/run-unit.sh
# Compiles the pure modules with tsc into a temp dir, then runs Node's built-in test runner (Node 18+).
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
npx --no-install tsc --ignoreConfig "$REPO/lib/format.ts" "$REPO/lib/dates.ts" "$REPO/lib/contact.ts" "$REPO/lib/safe.ts" "$REPO/lib/escape.ts" "$REPO/lib/phone.ts" "$REPO/lib/errors.ts" "$REPO/lib/pool.ts" "$REPO/lib/messages.ts" \
  --outDir "$OUT" --module commonjs --target es2020 --skipLibCheck --lib es2020,dom
CLASSI_LIB="$OUT" node --test "$REPO"/tests/unit/*.test.mjs
