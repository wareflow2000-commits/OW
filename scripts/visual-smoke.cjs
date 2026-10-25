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
    const aboutStatIcons = await page.locator('.page .stat-icon').allTextContents();
    assert.equal(aboutStatIcons.length, 3, 'About page must render all three summary cards.');
    assert.ok(aboutStatIcons.every(icon => icon.trim() && icon.trim() !== 'undefined'), 'About summary cards must not render undefined icons.');
    await page.screenshot({ path: path.join(outDir, 'desktop-about-ar.png'), fullPage: true });

    await page.locator('.topbar [data-action="toggle-lang"]').click();
    await page.waitForFunction(() => document.documentElement.dir === 'ltr');
    await page.locator('.page').waitFor({ state: 'visible' });
    assert.match(await page.locator('.page').innerText(), /About & formulas/i, 'About page must retain English translation.');
    const aboutEnglishIcons = await page.locator('.page .stat-icon').allTextContents();
    assert.equal(aboutEnglishIcons.length, 3, 'English About page must render all three summary cards.');
    assert.ok(aboutEnglishIcons.every(icon => icon.trim() && icon.trim() !== 'undefined'), 'English About summary cards must not render undefined icons.');
    await page.screenshot({ path: path.join(outDir, 'desktop-about-en.png'), fullPage: true });
    await page.locator('.topbar [data-action="toggle-lang"]').click();
    await page.waitForFunction(() => document.documentElement.dir === 'rtl');

    await page.evaluate(() => {
      state.page = 'reports';
      state.c10ReportKind = 'stock-summary';
      state.c10ReportFilters = {};
      render();
    });
    await page.locator('#c10-report-filter-form').waitFor({ state: 'visible' });
    await page.screenshot({ path: path.join(outDir, 'desktop-reports-ar.png'), fullPage: true });

    // Block reference-generation RPC in the smoke test so no production sequence is consumed.
    // Count attempts to verify the retry action really reissues the safe database request.
    let referenceRpcAttempts = 0;
    await page.route('**/rpc/next_transaction_reference*', route => {
      referenceRpcAttempts++;
      return route.fulfill({
        status: 403,
        contentType: 'application/json',
        body: JSON.stringify({ message: 'Blocked by visual smoke test; no database call is allowed.' })
      });
    });
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
    await page.locator('#modal-root [data-action="v12-tx-retry-reference"]').waitFor({ state: 'visible' });
    await page.waitForFunction(() => {
      const button = document.querySelector('#modal-root [data-action="v12-tx-retry-reference"]');
      return !!button && !button.disabled;
    }, { timeout: 5000 });
    assert.ok(referenceRpcAttempts >= 1, 'Opening New Request must attempt safe reference generation.');
    await page.locator('#modal-root [data-action="v12-tx-retry-reference"]').click();
    await page.waitForFunction(() => {
      const button = document.querySelector('#modal-root [data-action="v12-tx-retry-reference"]');
      return !!button && !button.disabled;
    }, { timeout: 5000 });
    assert.ok(referenceRpcAttempts >= 2, 'Retry must issue a second reference-generation request.');
    assert.equal(await page.locator('#v12-tx-form').count(), 1, 'Reference-generation failure and retry must keep the New Request form open.');
    assert.equal(await page.locator('#v12-tx-form [name="reference_no"]').inputValue(), '', 'A failed reference request must not invent a reference number.');
    // Change the item field to exercise the dependent shelf update and cross-IIFE bridge.
    await page.evaluate(() => {
      const item = document.querySelector('#v12-tx-form [name="draft_item_id"]');
      if (!item || item.options.length < 2) throw new Error('Seeded item option is unavailable in New Request.');
      item.value = item.options[1].value;
      item.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.waitForFunction(() => !!document.querySelector('#v12-tx-form [name="draft_shelf_id"]')?.value, { timeout: 5000 });
    assert.equal(await page.locator('#v12-tx-form').count(), 1, 'Changing the item must keep the form rendered.');

    // Verify the one-valid-shelf auto-selection is cleared when a second valid shelf appears.
    const selectedItemId = await page.locator('#v12-tx-form [name="draft_item_id"]').inputValue();
    await page.evaluate(() => {
      const shelfSelect = document.querySelector('#v12-tx-form [name="draft_shelf_id"]');
      const firstShelf = V5_DB.shelves.find(sh => sh.id === shelfSelect?.value);
      if (!firstShelf) throw new Error('The initially auto-selected valid shelf is missing.');
      V5_DB.shelves.push({
        id: 'smoke-shelf-second-valid',
        warehouse_id: firstShelf.warehouse_id,
        storage_area_id: firstShelf.storage_area_id,
        code: 'SMOKE-SHELF-02',
        name: 'Smoke Shelf 2',
        is_active: true
      });
      const item = document.querySelector('#v12-tx-form [name="draft_item_id"]');
      item.value = '';
      item.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.locator('#v12-tx-form').waitFor({ state: 'visible' });
    await page.evaluate(itemId => {
      const item = document.querySelector('#v12-tx-form [name="draft_item_id"]');
      if (!item) throw new Error('New Request item selector is missing after rerender.');
      item.value = itemId;
      item.dispatchEvent(new Event('change', { bubbles: true }));
    }, selectedItemId);
    await page.waitForFunction(() => {
      const shelf = document.querySelector('#v12-tx-form [name="draft_shelf_id"]');
      return !!shelf && shelf.options.length >= 3 && shelf.value === '';
    }, { timeout: 5000 });
    assert.equal(await page.locator('#v12-tx-form [name="draft_shelf_id"]').inputValue(), '', 'Multiple valid shelves must require an explicit selection.');

    // Verify owner preservation/invalidation using only browser-local seed records.
    const ownerTest = await page.evaluate(() => {
      const warehouse = V5_DB.warehouses.find(w => w.is_active !== false && c10AccessibleWarehouse(w.id));
      const area = warehouse && V5_DB.storage_areas.find(a => a.warehouse_id === warehouse.id && a.is_active !== false);
      if (!warehouse || !area) throw new Error('Owner dropdown smoke seed has no accessible warehouse/storage area.');
      const ownerA = { id: 'smoke-owner-a', code: 'OWNER-A', name: 'Smoke Owner A', name_ar: 'جهة اختبار أ', is_active: true, status: 'ACTIVE' };
      const ownerB = { id: 'smoke-owner-b', code: 'OWNER-B', name: 'Smoke Owner B', name_ar: 'جهة اختبار ب', is_active: true, status: 'ACTIVE' };
      const ownerC = { id: 'smoke-owner-c', code: 'OWNER-C', name: 'Smoke Owner C', name_ar: 'جهة اختبار ج', is_active: true, status: 'ACTIVE' };
      V5_DB.administrative_departments = (V5_DB.administrative_departments || []).filter(d => ![ownerA.id, ownerB.id, ownerC.id].includes(d.id));
      V5_DB.administrative_departments.push(ownerA, ownerB, ownerC);
      const shelfA = { id: 'smoke-owner-shelf-a', warehouse_id: warehouse.id, storage_area_id: area.id, code: 'OWNER-SHELF-A', name: 'Owner Shelf A', is_active: true };
      const shelfB = { id: 'smoke-owner-shelf-b', warehouse_id: warehouse.id, storage_area_id: area.id, code: 'OWNER-SHELF-B', name: 'Owner Shelf B', is_active: true };
      V5_DB.shelves = V5_DB.shelves.filter(sh => ![shelfA.id, shelfB.id].includes(sh.id));
      V5_DB.shelves.push(shelfA, shelfB);
      const itemA = { id: 'smoke-owner-item-a', code: 'OWNER-ITEM-A', item_number: 'OWNER-NUM-A', name_en: 'Owner Smoke Item A', name_ar: 'صنف اختبار أ', status: 'ACTIVE', base_unit: 'PCS' };
      const itemB = { id: 'smoke-owner-item-b', code: 'OWNER-ITEM-B', item_number: 'OWNER-NUM-B', name_en: 'Owner Smoke Item B', name_ar: 'صنف اختبار ب', status: 'ACTIVE', base_unit: 'PCS' };
      V5_DB.items = V5_DB.items.filter(i => ![itemA.id, itemB.id].includes(i.id));
      V5_DB.items.push(itemA, itemB);
      V5_DB.stock = V5_DB.stock.filter(row => ![itemA.id, itemB.id].includes(row.item_id));
      V5_DB.stock.push(
        { id: 'smoke-owner-stock-a', item_id: itemA.id, shelf_id: shelfA.id, storage_area_id: area.id, administrative_department_id: ownerA.id, quantity: 5, batch_no: 'BATCH-A', expiry_date: null },
        { id: 'smoke-owner-stock-b-a', item_id: itemA.id, shelf_id: shelfB.id, storage_area_id: area.id, administrative_department_id: ownerA.id, quantity: 5, batch_no: 'BATCH-A', expiry_date: null },
        { id: 'smoke-owner-stock-b-b', item_id: itemA.id, shelf_id: shelfB.id, storage_area_id: area.id, administrative_department_id: ownerB.id, quantity: 5, batch_no: 'BATCH-B', expiry_date: null },
        { id: 'smoke-owner-stock-item-b-b', item_id: itemB.id, shelf_id: shelfB.id, storage_area_id: area.id, administrative_department_id: ownerB.id, quantity: 5, batch_no: 'BATCH-B', expiry_date: null },
        { id: 'smoke-owner-stock-item-b-c', item_id: itemB.id, shelf_id: shelfB.id, storage_area_id: area.id, administrative_department_id: ownerC.id, quantity: 5, batch_no: 'BATCH-C', expiry_date: null }
      );
      state.v12TxMeta = { ...(state.v12TxMeta || {}), transaction_type: 'ISSUE', reference_no: '' };
      state.v12TxWarehouseId = warehouse.id;
      state.v12TxWarehouseManual = true;
      state.v12TxDraftLine = { item_id: itemA.id, shelf_id: '', quantity: 1, batch_no: '', expiry_date: '', administrative_department_id: '' };
      state.v12TxLines = [];
      window.orshapV12TxModal?.();
      return { itemAId: itemA.id, itemBId: itemB.id, shelfAId: shelfA.id, shelfBId: shelfB.id, ownerAId: ownerA.id };
    });

    // Exercise the real searchable-select UI against browser-local item records.
    const itemSelectBox = page.locator('#v12-tx-form select[name="draft_item_id"]').locator('xpath=..');
    await itemSelectBox.locator('.v13-select-trigger').click();
    const itemSearch = page.locator('.v13-select-panel:visible input.v13-select-search');
    for (const [query, expected] of [
      ['OWNER-ITEM-A', 'OWNER-ITEM-A'],
      ['OWNER-NUM-A', 'OWNER-NUM-A'],
      ['Owner Smoke Item A', 'Owner Smoke Item A']
    ]) {
      await itemSearch.fill(query);
      const visibleOptions = await page.locator('.v13-select-panel:visible [role="option"]:visible').allTextContents();
      assert.ok(visibleOptions.some(text => text.includes(expected)), `Item search must match ${query}.`);
      assert.ok(!visibleOptions.some(text => /OWNER-ITEM-B|OWNER-NUM-B|Owner Smoke Item B/.test(text)), `Item search ${query} must exclude the nonmatching item.`);
    }
    await itemSearch.fill('');
    await itemSelectBox.locator('.v13-select-trigger').click();

    await page.evaluate(id => {
      const shelf = document.querySelector('#v12-tx-form [name="draft_shelf_id"]');
      if (!shelf) throw new Error('Owner test shelf selector is missing.');
      shelf.value = id;
      shelf.dispatchEvent(new Event('change', { bubbles: true }));
    }, ownerTest.shelfAId);
    await page.waitForFunction(id => state.v12TxDraftLine?.administrative_department_id === id, ownerTest.ownerAId, { timeout: 5000 });
    await page.evaluate(id => {
      const shelf = document.querySelector('#v12-tx-form [name="draft_shelf_id"]');
      if (!shelf) throw new Error('Owner test shelf selector is missing after refresh.');
      shelf.value = id;
      shelf.dispatchEvent(new Event('change', { bubbles: true }));
    }, ownerTest.shelfBId);
    await page.waitForFunction(id => state.v12TxDraftLine?.administrative_department_id === id, ownerTest.ownerAId, { timeout: 5000 });
    await page.evaluate(id => {
      const item = document.querySelector('#v12-tx-form [name="draft_item_id"]');
      if (!item) throw new Error('Owner test item selector is missing.');
      item.value = id;
      item.dispatchEvent(new Event('change', { bubbles: true }));
    }, ownerTest.itemBId);
    await page.waitForFunction(() => state.v12TxDraftLine?.administrative_department_id === '', { timeout: 5000 });
    assert.equal(await page.locator('#v12-tx-form [name="draft_administrative_department_id"]').inputValue(), '', 'Changing to an item with different valid owners must clear the stale owner.');
    await page.screenshot({ path: path.join(outDir, 'desktop-owner-dropdown-state.png'), fullPage: true });

    // Verify review-before-save and failed-save retention. All transaction writes are intercepted.
    let createTransactionAttempts = 0;
    await page.route('**/rpc/create_transaction_with_lines*', route => {
      createTransactionAttempts++;
      return route.fulfill({
        status: 403,
        contentType: 'application/json',
        body: JSON.stringify({ message: 'Blocked by visual smoke test; no database write is allowed.' })
      });
    });
    const reviewSeed = await page.evaluate(() => {
      // Deterministic UUID-shaped records exist only in this browser's in-memory V5_DB.
      const warehouseId = '00000000-0000-4000-8000-00000000a001';
      const areaId = '00000000-0000-4000-8000-00000000a002';
      const shelfId = '00000000-0000-4000-8000-00000000a003';
      const itemId = '00000000-0000-4000-8000-00000000a004';
      const ownerId = '00000000-0000-4000-8000-00000000a005';
      V5_DB.warehouses = V5_DB.warehouses.filter(w => w.id !== warehouseId);
      V5_DB.warehouses.push({ id: warehouseId, code: 'SMOKE-REVIEW-WH', name: 'Review Smoke Warehouse', name_ar: 'مستودع اختبار المراجعة', is_active: true, status: 'ACTIVE' });
      V5_DB.storage_areas = V5_DB.storage_areas.filter(a => a.id !== areaId);
      V5_DB.storage_areas.push({ id: areaId, warehouse_id: warehouseId, code: 'SMOKE-REVIEW-AREA', name: 'Review Smoke Area', name_ar: 'منطقة اختبار المراجعة', is_active: true, status: 'ACTIVE' });
      V5_DB.administrative_departments = (V5_DB.administrative_departments || []).filter(d => d.id !== ownerId);
      V5_DB.administrative_departments.push({ id: ownerId, code: 'SMOKE-REVIEW-OWNER', name: 'Review Smoke Owner', name_ar: 'إدارة اختبار المراجعة', is_active: true, status: 'ACTIVE' });
      V5_DB.shelves = V5_DB.shelves.filter(sh => sh.id !== shelfId);
      V5_DB.shelves.push({ id: shelfId, warehouse_id: warehouseId, storage_area_id: areaId, code: 'SMOKE-REVIEW-SHELF', name: 'Review Smoke Shelf', is_active: true, status: 'ACTIVE', default_administrative_department_id: ownerId });
      V5_DB.items = V5_DB.items.filter(item => item.id !== itemId);
      V5_DB.items.push({ id: itemId, code: 'SMOKE-REVIEW-ITEM', item_number: 'SMOKE-REVIEW-001', name_en: 'Review Smoke Item', name_ar: 'صنف اختبار المراجعة', status: 'ACTIVE', is_active: true, base_unit: 'PCS' });
      state.session = { id: warehouseId, role: 'SUPER_ADMIN', profile: { id: warehouseId, role: 'SUPER_ADMIN', status: 'ACTIVE', assigned_warehouse_ids: [], custom_permissions: ['*'] } };
      state.v12TxMeta = { transaction_type: 'GRN', reference_no: 'SMOKE-REF-REVIEW-001', supplier: 'Smoke Supplier', receiver_name: 'Smoke Receiver', recipient_department_id: '', external_reference: '', adjustment_reason: '', notes: 'Browser smoke review only' };
      state.v12TxWarehouseId = warehouseId;
      state.v12TxWarehouseManual = true;
      state.v12TxDraftLine = { item_id: '', shelf_id: '', quantity: 1, batch_no: '', expiry_date: '', administrative_department_id: '' };
      state.v12TxLines = [{ item_id: itemId, shelf_id: shelfId, quantity: 1, batch_no: 'SMOKE-REVIEW-BATCH', expiry_date: null, administrative_department_id: ownerId }];
      window.orshapV12TxModal?.();
      return { warehouseId, shelfId, itemId, ownerId };
    });
    await page.locator('#v12-tx-form').waitFor({ state: 'visible' });
    await page.locator('#v12-tx-form [name="supplier"]').evaluate(el => el.dispatchEvent(new Event('input', { bubbles: true })));
    const reviewValidation = await page.evaluate(() => {
      const form = document.getElementById('v12-tx-form');
      const calc = window.orshapV12?.calculateDraft?.(Object.fromEntries(new FormData(form).entries()));
      return { valid: !!calc?.valid, errors: calc?.errors || [], reference: form?.querySelector('[name="reference_no"]')?.value || '' };
    });
    assert.ok(reviewValidation.valid, 'Seeded GRN must pass client validation before review. Details: ' + JSON.stringify(reviewValidation));
    await page.locator('#modal-root [data-action="v12-tx-save"]').click();
    await page.locator('.v13-tx-review-backdrop').waitFor({ state: 'visible', timeout: 5000 });
    assert.equal(createTransactionAttempts, 0, 'Opening the review overlay must not write the transaction.');
    await page.screenshot({ path: path.join(outDir, 'desktop-transaction-review-ar.png'), fullPage: true });
    const blockedCreateResponse = page.waitForResponse(response => response.url().includes('/rpc/create_transaction_with_lines') && response.status() === 403, { timeout: 5000 });
    await page.locator('[data-review-confirm]').click();
    await blockedCreateResponse;
    assert.ok(createTransactionAttempts >= 1, 'Confirming review must attempt the transaction RPC.');
    assert.equal(await page.locator('#v12-tx-form').count(), 1, 'Failed database save must keep the transaction form open for correction/retry.');
    assert.equal(await page.locator('.v13-tx-review-backdrop').count(), 0, 'Review overlay should close after confirm, while the editable form remains.');
    assert.equal(await page.locator('#v12-tx-form [name="reference_no"]').inputValue(), 'SMOKE-REF-REVIEW-001', 'Failed save must not clear or fabricate the reference.');
    await page.screenshot({ path: path.join(outDir, 'desktop-transaction-save-failure-ar.png'), fullPage: true });
    await page.evaluate(() => { state.modal = null; render(); });
    await page.unroute('**/rpc/create_transaction_with_lines*');

    await page.screenshot({ path: path.join(outDir, 'desktop-new-request-dashboard.png'), fullPage: true });

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
      const first = V5_DB.warehouses.find(w => w.is_active !== false && c10AccessibleWarehouse(w.id));
      if (!first) throw new Error('No accessible active local test warehouse is available.');
      V5_DB.storage_areas = V5_DB.storage_areas.filter(a => a.warehouse_id !== first.id);
      V5_DB.storage_areas.push(
        { id: 'smoke-area-2', warehouse_id: first.id, code: 'AREA-SMOKE-2', name: 'Smoke Area 2', is_active: true },
        { id: 'smoke-area-3', warehouse_id: first.id, code: 'AREA-SMOKE-3', name: 'Smoke Area 3', is_active: true }
      );
      state.v8FacilityWarehouseId = first.id;
      state.page = 'facilities';
      render();
    });
    // Open the actual modal renderer directly: the smoke-test account may not have
    // facility-management permission, which correctly disables the UI button.
    await page.evaluate(() => v8OpenFacility('shelf'));
    await page.locator('#v8-facility-form').waitFor({ state: 'visible' });
    await page.evaluate(() => {
      const warehouse = document.querySelector('#v8-facility-form select[name="warehouse_id"]');
      if (!warehouse) throw new Error('Active shelf modal warehouse selector is missing.');
      const accessible = V5_DB.warehouses.find(w => w.is_active !== false && c10AccessibleWarehouse(w.id));
      warehouse.value = accessible.id;
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

    // Exercise the older shelf registry form as well as the active facilities modal.
    await page.evaluate(() => handleAction('v12-add-shelf'));
    await page.locator('#v12-fac-form').waitFor({ state: 'visible' });
    await page.evaluate(() => {
      const warehouse = document.querySelector('#v12-fac-form select[name="warehouse_id"]');
      const accessible = V5_DB.warehouses.find(w => w.is_active !== false && c10AccessibleWarehouse(w.id));
      if (!warehouse || !accessible) throw new Error('Legacy shelf form warehouse selector is missing.');
      warehouse.value = accessible.id;
      warehouse.dispatchEvent(new Event('change', { bubbles: true }));
    });
    await page.waitForFunction(() => {
      const area = document.querySelector('#v12-fac-form select[name="storage_area_id"]');
      return !!area && area.options.length === 3 && area.value === '';
    }, { timeout: 5000 });
    const legacyAreaOptions = await page.locator('#v12-fac-form select[name="storage_area_id"] option').evaluateAll(options => options.map(o => o.value));
    assert.deepEqual(legacyAreaOptions.sort(), ['', 'smoke-area-2', 'smoke-area-3'].sort(), 'Legacy shelf form must include an empty option and not silently choose the first of multiple areas.');
    await page.screenshot({ path: path.join(outDir, 'desktop-legacy-shelf-area-dependency.png'), fullPage: true });
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
