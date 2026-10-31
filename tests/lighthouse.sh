#!/bin/sh
# Lighthouse (performance, accessibility, best practices, SEO) on the main public pages of a running build.
# CI only: uses Playwright's Chromium and a pinned Lighthouse fetched with npx. Usage: sh tests/lighthouse.sh http://localhost:3000
BASE="${1:-http://localhost:3000}"
case "$BASE" in *classi.click*|*vercel.app*) echo "local builds only"; exit 1;; esac
CHROME="$(node -e "console.log(require('playwright').chromium.executablePath())" 2>/dev/null || node -e "console.log(require('@playwright/test').chromium.executablePath())")"
OFFER="$(psql "$E2E_DB_URL" -Atc "select id from offerings where active and review_status = 'approved' and type = 'private' limit 1")"
mkdir -p /tmp/lh
echo "page | form factor | performance | accessibility | best practices | SEO | LCP ms | CLS | TBT ms"
for p in "/" "/search" "/offer/$OFFER" "/login"; do
  for ff in mobile desktop; do
    name="$(echo "$p" | tr '/' '_')-$ff"
    if [ "$ff" = desktop ]; then preset="--preset=desktop"; else preset=""; fi
    CHROME_PATH="$CHROME" npx --yes lighthouse@12.6.1 "$BASE$p" $preset --quiet --chrome-flags="--headless=new --no-sandbox" \
      --only-categories=performance,accessibility,best-practices,seo --output=json --output-path="/tmp/lh/$name.json" >/dev/null 2>&1 || { echo "$p | $ff | lighthouse failed"; continue; }
    node -e '
      const r = require(process.argv[1]); const c = r.categories, a = r.audits; const s = (k) => Math.round((c[k]?.score ?? 0) * 100);
      console.log([process.argv[2], process.argv[3], s("performance"), s("accessibility"), s("best-practices"), s("seo"),
        Math.round(a["largest-contentful-paint"].numericValue), a["cumulative-layout-shift"].numericValue.toFixed(3), Math.round(a["total-blocking-time"].numericValue)].join(" | "));
      for (const [k, v] of Object.entries(a)) if (v.score !== null && v.score < 0.9 && ["accessibility","seo","best-practices"].some((cat) => c[cat].auditRefs.some((x) => x.id === k && x.weight > 0))) console.log("   - " + k + ": " + v.title);
    ' "/tmp/lh/$name.json" "$p" "$ff"
  done
done
