# ORSHAP WMS v13.9.58 — canonical storage-area report patch

## Scope
- Adds `get_stock_summary_by_storage_area(p_start_date, p_end_date, p_warehouse_id, p_storage_area_id, p_category_id)`.
- Uses `inventory_ledger.storage_area_id`, `stock.storage_area_id`, and `item_categories` for report filtering and labels.
- Checks active authenticated profile, report permission, assigned warehouse scope, date range, and the current storage-area owner relation.
- Removes anonymous/PUBLIC execution on the new RPC; grants execution to authenticated and service_role.
- Updates report UI filters in `app.js` to use `storage_areas` and `shelves.storage_area_id`, not legacy `zones` IDs, for report location filtering.

## Verification performed
- Both database migrations were applied to the connected Supabase project.
- A follow-up migration corrected storage-area validation to use the current authoritative `storage_areas.warehouse_id` owner relation; this avoids rejecting new areas before the mapping-table write paths are rolled out.
- RPC call returned two matching sample items for the selected warehouse/storage area.
- Category filter returned only the two items in the selected category.
- Privileges verified: `anon` cannot execute; `authenticated` and `service_role` can execute.
- Local `node --check app.js` passed after applying the same targeted replacements.
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
