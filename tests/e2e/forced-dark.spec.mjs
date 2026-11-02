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
  test(`the browser never repaints ${path}: own dark palette, light mode stays light`, async ({ baseURL }, info) => {
    test.skip(info.project.name !== "mobile", "one run is enough (the browsers are launched here)");
    const strip = { x: 0, y: 200, width: 12, height: 400 };          // an empty margin of the page background
    const shot = async (args, colorScheme) => {
      const browser = await chromium.launch({ args, channel: "chromium" });
      try {
        const ctx = await browser.newContext({ baseURL, viewport: { width: 390, height: 844 }, colorScheme, locale: "ar" });
        const page = await ctx.newPage();
        await page.goto(path, { waitUntil: "networkidle" });
        await page.waitForTimeout(2600);                              // the opening splash (dark blue) fades out first
        return await brightness(page, strip);
      } finally { await browser.close(); }
    };
    const FORCED = ["--force-dark-mode", "--enable-features=WebContentsForceDark"];
    // control: forced darkening really is active in this browser (a plain light page without a dark palette is inverted)
    {
      const browser = await chromium.launch({ args: FORCED, channel: "chromium" });
      try {
        const page = await (await browser.newContext({ viewport: { width: 390, height: 844 }, colorScheme: "dark" })).newPage();
        await page.setContent('<html><body style="margin:0;background:#FBF8F2;height:100vh"></body></html>');
        const control = await brightness(page, strip);
        expect(control, `control: a light page without its own dark palette is inverted (${control.toFixed(0)})`).toBeLessThan(100);
      } finally { await browser.close(); }
    }
    const light = await shot([], "light");
    const ownDark = await shot([], "dark");
    const forced = await shot(FORCED, "dark");
    console.log(`[forced-dark] ${path} light ${light.toFixed(0)} | own dark ${ownDark.toFixed(0)} | forced dark ${forced.toFixed(0)}`);
    const v = `light ${light.toFixed(0)}, own dark ${ownDark.toFixed(0)}, forced ${forced.toFixed(0)}`;
    expect(light, `light mode background (${v})`).toBeGreaterThan(200);
    expect(ownDark, `the site's own dark background #12151F (${v})`).toBeLessThan(40);
    // forced darkening must not change anything: same pixels as the site's own dark mode
    expect(Math.abs(forced - ownDark), `forced dark mode repainted the page (${v})`).toBeLessThan(4);
  });
}
