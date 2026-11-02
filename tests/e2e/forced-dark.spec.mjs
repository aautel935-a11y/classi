// The site has a light design only. Browsers that darken pages on their own (Chrome on Android "darken websites",
// Chromium's forced dark mode) used to invert it: black background, low-contrast text, and the faint notebook lines
// turned into bright blue stripes. The page opts out with color-scheme "only light"; this test opens pages in
// Chromium with forced dark mode on and checks, from the rendered pixels, that the background stays light.
import { test, expect, chromium } from "@playwright/test";

test.describe.configure({ mode: "serial" });

/** Average brightness (0-255) of a strip of the rendered page, sampled from a real screenshot. */
async function brightness(page, clip) {
  const png = (await page.screenshot({ clip })).toString("base64");
  const probe = await page.context().newPage();
  try {
    return await probe.evaluate(async (data) => {
      const img = new Image();
      img.src = `data:image/png;base64,${data}`;
      await img.decode();
      const c = document.createElement("canvas");
      c.width = img.width; c.height = img.height;
      const g = c.getContext("2d");
      g.drawImage(img, 0, 0);
      const d = g.getImageData(0, 0, c.width, c.height).data;
      let sum = 0;
      for (let i = 0; i < d.length; i += 4) sum += 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
      return sum / (d.length / 4);
    }, png);
  } finally { await probe.close(); }
}

for (const path of ["/login", "/"]) {
  test(`forced dark mode does not darken ${path}`, async ({ baseURL }, info) => {
    test.skip(info.project.name !== "mobile", "one run is enough (the forced-dark browser is launched here)");
    const browser = await chromium.launch({ args: ["--force-dark-mode", "--enable-features=WebContentsForceDark"] });
    try {
      const ctx = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 }, colorScheme: "dark", locale: "ar" });
      const page = await ctx.newPage();
      await page.goto(path, { waitUntil: "networkidle" });
      // an empty margin of the page background (left gutter, below the header)
      const b = await brightness(page, { x: 0, y: 200, width: 12, height: 400 });
      console.log(`[forced-dark] ${path} background brightness ${b.toFixed(0)}`);
      expect(b, "page background under forced dark mode (light design ~248)").toBeGreaterThan(200);
      await ctx.close();
    } finally { await browser.close(); }
  });
}
