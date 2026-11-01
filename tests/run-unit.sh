#!/bin/sh
# Unit tests for lib/*.ts. Usage (from anywhere): sh tests/run-unit.sh
# Compiles the pure modules with tsc into a temp dir (own tsconfig, so any TypeScript version works), then runs
# Node's built-in test runner (Node 18+).
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
echo 'declare const process: { env: Record<string, string | undefined> };' > "$OUT/env.d.ts"
cat > "$OUT/tsconfig.json" <<JSON
{ "compilerOptions": { "outDir": "$OUT", "module": "commonjs", "target": "es2020", "skipLibCheck": true, "lib": ["es2020", "dom"], "types": [], "rootDir": "$REPO/lib" },
  "files": ["$OUT/env.d.ts", "$REPO/lib/format.ts", "$REPO/lib/dates.ts", "$REPO/lib/contact.ts", "$REPO/lib/safe.ts", "$REPO/lib/escape.ts",
            "$REPO/lib/phone.ts", "$REPO/lib/errors.ts", "$REPO/lib/pool.ts", "$REPO/lib/messages.ts", "$REPO/lib/search.ts", "$REPO/lib/fetch-all.ts", "$REPO/lib/sms.ts", "$REPO/lib/deploy-guard.ts"] }
JSON
npx --no-install tsc -p "$OUT/tsconfig.json"
CLASSI_LIB="$OUT" node --test "$REPO"/tests/unit/*.test.mjs
