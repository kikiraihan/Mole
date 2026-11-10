// Render setiap <section> di mockup.html menjadi PNG (@2x) di folder ini.
// Pakai: node macos-app/_tech_debt/combined-menubar-glyph/render.js
const path = require('path');
const { chromium } = require('playwright');

const names = {
  s1: '01-menubar-varian-a-b.png',
  s2: '02-zoom-anatomi.png',
  s3: '03-tabel-level.png',
  s4: '04-interaksi-region-tooltip-popover.png',
  s5: '05-kondisi-kritis.png',
};

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 880, height: 900 }, deviceScaleFactor: 2 });
  await page.goto('file://' + path.join(__dirname, 'mockup.html'));
  for (const [id, file] of Object.entries(names)) {
    await page.locator('#' + id).screenshot({ path: path.join(__dirname, file) });
    console.log('wrote', file);
  }
  await browser.close();
})();
