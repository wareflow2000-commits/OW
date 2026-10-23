# ORSHAP WMS v13.9.58 — canonical storage-area report patch

## Scope
- Adds `get_stock_summary_by_storage_area(p_start_date, p_end_date, p_warehouse_id, p_storage_area_id, p_category_id)`.
- Uses `inventory_ledger.storage_area_id`, `stock.storage_area_id`, and `item_categories` for report filtering and labels.
- Checks active authenticated profile, report permission, assigned warehouse scope, date range, and the current storage-area owner relation.
- Removes anonymous/PUBLIC execution on the new RPC; grants execution to authenticated and service_role.
- Adds an Accounting Stock Summary report to the v13.9.58 report center; it calls the database RPC and supports storage-area and item-category filters.
- Updates report UI filters in `app.js` to use `storage_areas` and `shelves.storage_area_id`, not legacy `zones` IDs, for report location filtering.

## Verification performed
- Both database migrations were applied to the connected Supabase project.
- A follow-up migration corrected storage-area validation to use the current authoritative `storage_areas.warehouse_id` owner relation; this avoids rejecting new areas before the mapping-table write paths are rolled out.
- RPC call returned two matching sample items for the selected warehouse/storage area.
- Category filter returned only the two items in the selected category.
- Privileges verified: `anon` cannot execute; `authenticated` and `service_role` can execute.
- Local `node --check app.js` passed after applying the targeted report-filter and RPC integration changes.
- Existing data and stock balances were not changed by the report query tests.

## Explicitly not included
- No deletion of `zones` or `sections`.
- No replacement of the legacy `get_stock_summary_report` RPC yet.
- No change to transaction posting, transfer receipt, stocktake settlement, or historical ledger rows.
- No claim that shared storage areas are fully enabled: existing shelf and inventory guards still enforce single-warehouse ownership for a storage area.
- Remaining forms, CRUD handlers, import paths, triggers, and RPCs still reference legacy `zone_id`/`section_id`; a coordinated migration is required before removing those objects.

## Next required phase
1. Convert facility/item/shelf CRUD and import/export to canonical storage-area/category relations.
2. Replace zone/section parameters in reports and posting/ledger helpers with storage-area/category identifiers while preserving wrapper compatibility.
3. Decide and implement shared-area ownership model (association table plus warehouse-scoped shelves/stock) before relaxing location guards.
4. Re-run ledger/stock reconciliation and security advisors, then remove legacy columns/tables only after zero live dependencies.


## Follow-up UI compatibility changes (2026-10-23)
- Item editor now selects a canonical `item_categories.id` and saves both `category_id` and the mirrored legacy `category` label. Database trigger `sync_item_category_refs` keeps the text label aligned.
- Item default location now selects `storage_areas.id` and saves `default_storage_area_id`, while retaining the mapped `default_zone_id` for the existing compatibility trigger.
- Shelf creation no longer requires a legacy section. It sets `section_id` to null when omitted and carries the canonical `storage_area_id` resolved from the selected legacy zone. This matches the current schema, where `shelves.section_id` is nullable and the demo dataset has no section records.
- Applied the same targeted source transformations to the available v13.9.58 source snapshot and `node --check` passed. The exact current GitHub `app.js` was also re-fetched after each commit; no full browser end-to-end run was performed.
- Current DB completeness check: 6/6 items have category IDs and default storage areas; 6/6 shelves, 9/9 stock rows, 25/25 transaction lines and 25/25 inventory-ledger rows have storage-area IDs. These are completeness checks, not full ledger certification.
- Still not migrated: facility CRUD continues to create legacy zones which synchronize into storage areas; the legacy sections table, zone/section foreign keys, and old RPC signatures remain. Shared-area support remains a separate design/migration phase.

- Added and verified a canonical unique index on `shelves(storage_area_id, code)` (partial for non-null areas). Preflight found no duplicate pairs. The legacy `(zone_id, code)` uniqueness remains for compatibility until zone dependencies are removed.

- Updated the inventory table to display the canonical storage-area name and item category rather than legacy zone/section labels. Category labels are HTML-escaped before rendering.
