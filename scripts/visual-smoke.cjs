'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const baseURL = process.env.ORSHAP_BASE_URL || 'http://127.0.0.1:4173';
  const outDir = process.env.ORSHAP_SCREENSHOT_DIR || 'artifacts/visual-smoke';
  fs.mkdirSync(outDir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 1 });
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));

  try {
    await page.goto(baseURL, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.locator('#auth-form').waitFor({ state: 'visible', timeout: 45000 });
    await page.screenshot({ path: path.join(outDir, 'desktop-login-ar.png'), fullPage: true });
    assert.equal(await page.locator('html').getAttribute('dir'), 'rtl', 'Arabic login must default to RTL.');
    assert.equal(await page.locator('.login-card').count(), 1, 'Login card must render once.');

    await page.locator('#auth-form [data-action="toggle-lang"]').click();
    await page.waitForFunction(() => document.documentElement.dir === 'ltr');
    assert.match(await page.locator('.login-welcome').innerText(), /Welcome back/i);
    await page.screenshot({ path: path.join(outDir, 'desktop-login-en.png'), fullPage: true });

    await page.evaluate(() => {
      state.login = true;
      state.lang = 'ar';
      state.theme = 'light';
      state.page = 'dashboard';
      render();
    });
    await page.locator('.app-shell').waitFor({ state: 'visible' });
    await page.screenshot({ path: path.join(outDir, 'desktop-shell-rtl.png'), fullPage: true });
    const rtlDesktop = await page.evaluate(() => {
      const sidebar = document.querySelector('.v13-sidebar, .sidebar').getBoundingClientRect();
      const main = document.querySelector('.main').getBoundingClientRect();
      return { viewport: innerWidth, documentWidth: document.documentElement.scrollWidth, sidebarLeft: sidebar.left, sidebarRight: sidebar.right, mainLeft: main.left, mainRight: main.right };
    });
    assert.ok(rtlDesktop.documentWidth <= rtlDesktop.viewport + 1, 'Desktop RTL layout must not overflow horizontally.');
    assert.ok(rtlDesktop.sidebarLeft >= rtlDesktop.mainRight - 2, 'RTL desktop sidebar must be on the right of the main content.');

    await page.locator('.topbar [data-action="toggle-lang"]').click();
    await page.waitForFunction(() => document.documentElement.dir === 'ltr');
    const ltrDesktop = await page.evaluate(() => {
      const sidebar = document.querySelector('.v13-sidebar, .sidebar').getBoundingClientRect();
      const main = document.querySelector('.main').getBoundingClientRect();
      return { viewport: innerWidth, documentWidth: document.documentElement.scrollWidth, sidebarLeft: sidebar.left, sidebarRight: sidebar.right, mainLeft: main.left, mainRight: main.right };
    });
    assert.ok(ltrDesktop.documentWidth <= ltrDesktop.viewport + 1, 'Desktop LTR layout must not overflow horizontally.');
    assert.ok(ltrDesktop.sidebarRight <= ltrDesktop.mainLeft + 2, 'LTR desktop sidebar must be on the left of the main content.');
    await page.screenshot({ path: path.join(outDir, 'desktop-shell-ltr.png'), fullPage: true });

    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(() => {
      state.login = false;
      state.lang = 'ar';
      state.theme = 'light';
      state.page = 'dashboard';
      render();
    });
    await page.locator('#auth-form').waitFor({ state: 'visible' });
    const mobileLogin = await page.evaluate(() => ({ viewport: innerWidth, documentWidth: document.documentElement.scrollWidth, bodyWidth: document.body.scrollWidth }));
    assert.ok(mobileLogin.documentWidth <= mobileLogin.viewport + 1, 'Mobile login must not overflow horizontally.');
    await page.screenshot({ path: path.join(outDir, 'mobile-login-ar.png'), fullPage: true });

    await page.evaluate(() => {
      state.login = true;
      state.lang = 'ar';
      state.theme = 'light';
      state.page = 'dashboard';
      render();
    });
    await page.locator('.v13-bottom-nav').waitFor({ state: 'visible' });
    const mobileShell = await page.evaluate(() => {
      const nav = document.querySelector('.v13-bottom-nav');
      const topbar = document.querySelector('.v13-topbar, .topbar');
      const page = document.querySelector('.page');
      return {
        viewport: innerWidth,
        documentWidth: document.documentElement.scrollWidth,
        buttonCount: nav.querySelectorAll('button').length,
        quickScan: !!nav.querySelector('[data-action="v13-scan-qr"]'),
        navPosition: getComputedStyle(nav).position,
        navBottom: nav.getBoundingClientRect().bottom,
        topbarPosition: getComputedStyle(topbar).position,
        topbarTop: topbar.getBoundingClientRect().top,
        pagePaddingBottom: getComputedStyle(page).paddingBottom
      };
    });
    assert.ok(mobileShell.documentWidth <= mobileShell.viewport + 1, 'Mobile shell must not overflow horizontally.');
    assert.equal(mobileShell.buttonCount, 5, 'Mobile navigation must contain exactly five actions.');
    assert.equal(mobileShell.quickScan, true, 'Mobile navigation must include the quick-scan action.');
    assert.equal(mobileShell.navPosition, 'fixed', 'Mobile bottom navigation must be fixed.');
    assert.equal(mobileShell.topbarPosition, 'fixed', 'Mobile topbar must be fixed.');
    assert.ok(mobileShell.navBottom >= 843, 'Mobile bottom navigation must reach the viewport bottom.');
    await page.screenshot({ path: path.join(outDir, 'mobile-shell-ar.png'), fullPage: true });

    await page.locator('.v13-bottom-nav [data-page="transactions"]').click();
    await page.waitForFunction(() => state.page === 'transactions');
    assert.equal(await page.evaluate(() => state.page), 'transactions', 'Mobile navigation must change the active page.');
    await page.screenshot({ path: path.join(outDir, 'mobile-transactions-ar.png'), fullPage: true });

    assert.deepEqual(pageErrors, [], 'No uncaught browser JavaScript errors are allowed during the visual smoke test.');
    console.log(JSON.stringify({ status: 'passed', screenshots: fs.readdirSync(outDir), rtlDesktop, ltrDesktop, mobileLogin, mobileShell, pageErrors }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
