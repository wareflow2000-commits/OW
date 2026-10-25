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
  const consoleErrors = [];
  const failedRequests = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  page.on('console', msg => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  page.on('requestfailed', request => failedRequests.push({ url: request.url(), error: request.failure()?.errorText || 'unknown' }));

  try {
    await page.goto(baseURL, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await page.locator('#auth-form').waitFor({ state: 'visible', timeout: 45000 });
    await page.screenshot({ path: path.join(outDir, 'desktop-login-ar.png'), fullPage: true });
    assert.equal(await page.locator('html').getAttribute('dir'), 'rtl', 'Arabic login must default to RTL.');
    assert.equal(await page.locator('.login-card').count(), 1, 'Login card must render once.');

    await page.locator('.login-preferences button').first().click();
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
    const desktopNavDisplay = await page.locator('.v13-bottom-nav').evaluate(el => getComputedStyle(el).display);
    assert.equal(desktopNavDisplay, 'none', 'Mobile bottom navigation must be hidden on desktop.');
    await page.screenshot({ path: path.join(outDir, 'desktop-shell-rtl.png'), fullPage: true });
    const rtlDesktop = await page.evaluate(() => {
      const sidebar = document.querySelector('.v13-sidebar, .sidebar').getBoundingClientRect();
      const main = document.querySelector('.main').getBoundingClientRect();
      return { viewport: innerWidth, documentWidth: document.documentElement.scrollWidth, sidebarLeft: sidebar.left, sidebarRight: sidebar.right, mainLeft: main.left, mainRight: main.right };
    });
    assert.ok(rtlDesktop.documentWidth <= rtlDesktop.viewport + 1, 'Desktop RTL layout must not overflow horizontally.');
    assert.ok(rtlDesktop.sidebarLeft >= rtlDesktop.mainRight - 2, 'RTL desktop sidebar must be on the right of the main content.');

    // Exercise the three reported runtime failures on the real browser-rendered app.
    await page.evaluate(() => {
      state.page = 'about';
      render();
    });
    await page.locator('.page').waitFor({ state: 'visible' });
    assert.match(await page.locator('.page').innerText(), /حول النظام|About/i, 'About page must render without a ReferenceError.');
    await page.screenshot({ path: path.join(outDir, 'desktop-about-ar.png'), fullPage: true });

    await page.evaluate(() => {
      state.page = 'reports';
      state.c10ReportKind = 'stock-summary';
      state.c10ReportFilters = {};
      render();
    });
    await page.locator('#c10-report-filter-form').waitFor({ state: 'visible' });
    await page.screenshot({ path: path.join(outDir, 'desktop-reports-ar.png'), fullPage: true });

    // Block reference-generation RPC in the smoke test so no production sequence is consumed.
    await page.route('**/rpc/next_transaction_reference*', route => route.fulfill({
      status: 403,
      contentType: 'application/json',
      body: JSON.stringify({ message: 'Blocked by visual smoke test; no database call is allowed.' })
    }));
    await page.evaluate(() => {
      state.session = { id: 'smoke-admin', role: 'SUPER_ADMIN', profile: { id: 'smoke-admin', role: 'SUPER_ADMIN', status: 'ACTIVE', assigned_warehouse_ids: [], custom_permissions: ['*'] } };
      state.page = 'dashboard';
      state.c10ReportKind = '';
      render();
    });
    await page.locator('.page [data-action="v12-new-tx"]').first().click();
    await page.waitForTimeout(500);
    const dashboardRequestDebug = await page.evaluate(() => ({ page: state.page, hasModalState: !!state.modal, modalRootHasForm: !!document.querySelector('#modal-root #v12-tx-form'), appText: document.querySelector('#app')?.innerText?.slice(0, 250) || '' }));
    assert.ok(dashboardRequestDebug.modalRootHasForm, 'Dashboard New Request button must open the form. Debug: ' + JSON.stringify({ dashboardRequestDebug, pageErrors }));
    // Change the item field to exercise the dependent shelf update and cross-IIFE bridge.
    await page.evaluate(() => {
      const item = document.querySelector('#v12-tx-form [name="draft_item_id"]');
      if (!item || item.options.length < 2) throw new Error('Seeded item option is unavailable in New Request.');
      item.value = item.options[1].value;
      item.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.waitForFunction(() => !!document.querySelector('#v12-tx-form [name="draft_shelf_id"]')?.value, { timeout: 5000 });
    assert.equal(await page.locator('#v12-tx-form').count(), 1, 'Changing the item must keep the form rendered.');
    await page.screenshot({ path: path.join(outDir, 'desktop-new-request-dashboard.png'), fullPage: true });
    await page.locator('#modal-root [data-action="close-modal"]').last().click();

    await page.evaluate(() => {
      state.page = 'transactions';
      render();
    });
    await page.locator('.page [data-action="v12-new-tx"]').first().click();
    await page.waitForTimeout(500);
    const transactionsRequestDebug = await page.evaluate(() => ({ page: state.page, hasModalState: !!state.modal, modalRootHasForm: !!document.querySelector('#modal-root #v12-tx-form'), appText: document.querySelector('#app')?.innerText?.slice(0, 250) || '' }));
    assert.ok(transactionsRequestDebug.modalRootHasForm, 'Transactions New Request button must open the form. Debug: ' + JSON.stringify({ transactionsRequestDebug, pageErrors }));
    await page.screenshot({ path: path.join(outDir, 'desktop-new-request-transactions.png'), fullPage: true });
    await page.locator('#modal-root [data-action="close-modal"]').last().click();
    // Exercise the active facilities shelf modal's warehouse -> storage-area dependency.
    // Seed records exist only in this browser process; do not save or call any database RPC.
    await page.evaluate(() => {
      V5_DB.warehouses.push({ id: 'smoke-wh-2', code: 'WH-SMOKE-2', name: 'Smoke Warehouse 2', is_active: true });
      V5_DB.storage_areas.push(
        { id: 'smoke-area-2', warehouse_id: 'smoke-wh-2', code: 'AREA-SMOKE-2', name: 'Smoke Area 2', is_active: true },
        { id: 'smoke-area-3', warehouse_id: 'smoke-wh-2', code: 'AREA-SMOKE-3', name: 'Smoke Area 3', is_active: true }
      );
      state.v8FacilityWarehouseId = 'smoke-wh-2';
      state.page = 'facilities';
      render();
    });
    await page.locator('[data-action="open-shelf"], [data-action="v8-open-shelf"]').first().click();
    await page.locator('#v8-facility-form').waitFor({ state: 'visible' });
    await page.evaluate(() => {
      const warehouse = document.querySelector('#v8-facility-form select[name="warehouse_id"]');
      if (!warehouse) throw new Error('Active shelf modal warehouse selector is missing.');
      warehouse.value = 'smoke-wh-2';
      warehouse.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.waitForFunction(() => {
      const area = document.querySelector('#v8-facility-form select[name="storage_area_id"]');
      return !!area && area.options.length === 3 && area.value === '';
    }, { timeout: 5000 });
    const areaOptions = await page.locator('#v8-facility-form select[name="storage_area_id"] option').evaluateAll(options => options.map(o => o.value));
    assert.deepEqual(areaOptions.sort(), ['', 'smoke-area-2', 'smoke-area-3'].sort(), 'Active shelf modal must list only areas for its selected warehouse and require explicit choice when multiple exist.');
    await page.screenshot({ path: path.join(outDir, 'desktop-shelf-area-dependency.png'), fullPage: true });
    await page.locator('#modal-root [data-action="close-modal"]').last().click();

    await page.unroute('**/rpc/next_transaction_reference*');

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
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await page.waitForTimeout(100);
    const mobileBottomReachability = await page.evaluate(() => {
      const nav = document.querySelector('.v13-bottom-nav').getBoundingClientRect();
      const pageContent = document.querySelector('.page');
      const lastContent = pageContent.lastElementChild.getBoundingClientRect();
      const topbar = document.querySelector('.v13-topbar').getBoundingClientRect();
      return { navTop: nav.top, lastContentBottom: lastContent.bottom, topbarTop: topbar.top, scrollY: window.scrollY };
    });
    assert.ok(mobileBottomReachability.scrollY > 0, 'Mobile document must scroll when content exceeds the viewport.');
    assert.ok(mobileBottomReachability.lastContentBottom <= mobileBottomReachability.navTop + 1, 'The final content block must be reachable above the fixed bottom navigation.');
    assert.ok(mobileBottomReachability.topbarTop <= 1, 'Fixed mobile topbar must remain anchored at the viewport top while scrolling.');
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: path.join(outDir, 'mobile-shell-ar.png'), fullPage: true });

    await page.locator('.v13-bottom-nav [data-page="transactions"]').click();
    await page.waitForFunction(() => state.page === 'transactions');
    assert.equal(await page.evaluate(() => state.page), 'transactions', 'Mobile navigation must change the active page.');
    await page.screenshot({ path: path.join(outDir, 'mobile-transactions-ar.png'), fullPage: true });

    await page.route('**/rpc/next_transaction_reference*', route => route.fulfill({
      status: 403,
      contentType: 'application/json',
      body: JSON.stringify({ message: 'Blocked by visual smoke test; no database call is allowed.' })
    }));
    await page.locator('.page [data-action="v12-new-tx"]').first().click();
    await page.waitForTimeout(300);
    const mobileRequestDebug = await page.evaluate(() => ({ hasModalState: !!state.modal, modalRootHasForm: !!document.querySelector('#modal-root #v12-tx-form') }));
    assert.ok(mobileRequestDebug.modalRootHasForm, 'Mobile New Request button must open the form. Debug: ' + JSON.stringify({ mobileRequestDebug, pageErrors }));
    await page.screenshot({ path: path.join(outDir, 'mobile-new-request.png'), fullPage: true });
    await page.locator('#modal-root [data-action="close-modal"]').last().click();
    await page.unroute('**/rpc/next_transaction_reference*');


    const unexpectedConsoleErrors = consoleErrors.filter(message => !/Failed to load resource: the server responded with a status of (401|403)\b/.test(message));
    assert.deepEqual(pageErrors, [], 'No uncaught browser JavaScript errors are allowed during the visual smoke test.');
    assert.deepEqual(unexpectedConsoleErrors, [], 'Unexpected browser console errors: ' + JSON.stringify(unexpectedConsoleErrors));
    assert.deepEqual(failedRequests, [], 'Network requests must not fail: ' + JSON.stringify(failedRequests));
    console.log(JSON.stringify({ status: 'passed', screenshots: fs.readdirSync(outDir), rtlDesktop, ltrDesktop, mobileLogin, mobileShell, pageErrors, expectedHttpErrors: consoleErrors, failedRequests }, null, 2));
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
