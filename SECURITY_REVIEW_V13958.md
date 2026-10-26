# ORSHAP WMS v13.9.58 — Security review notes

Date: 2026-10-24
Project: wms-WFLOE (nyhyoyjznbpilailccof)
Branch: audit/v13.9.58-dropdown-unification

## Verified database findings

- 73 functions in public are marked SECURITY DEFINER.
- 34 of those functions are executable by authenticated; none of the 73 are executable by anon according to has_function_privilege.
- All 73 public SECURITY DEFINER functions have a pinned search_path setting in pg_proc.proconfig.
- Reviewed exposed workflow functions and wrappers for identity/profile checks, permission checks or delegation to guarded canonical functions, warehouse scope, row/advisory locks, and duplicate-posting guards. A read-only/rollback authorization test with an active CLERK confirmed that report access, transfer creation, and opening-balance creation are rejected when the required privileges are absent. In particular, the transfer-order legacy wrapper delegates to dispatch_stock_transfer_order_v2; the old one-shot receipt wrappers were explicitly revoked from PUBLIC, anon, and authenticated and verified non-executable after the direct ACL change.
- Live reconciliation after concurrent return confirmation and cleanup: stock rows = 1; stock total = 100; inventory-ledger delta total = 100; transaction-ledger quantity total = 100; no test transfer, test transaction, or receipt-idempotency rows remain.
- The static application and Supabase client source contain no GraphQL client calls; the app uses PostgREST/Auth.

## Remaining security findings — do not mark as closed

### GraphQL exposure

Supabase Security Advisor still reports 28 authenticated-visible GraphQL relations. Table-level SELECT grants are used by the current PostgREST client, so bulk revoking table grants would break required app reads and is not an acceptable blanket fix.

The graphql_public schema and graphql extension functions are owned by managed role supabase_admin. Attempts to revoke function/schema ACLs through the connected role did not change their effective ACLs; SET ROLE supabase_admin is denied. No successful GraphQL restriction is claimed. Resolve this through a supported Supabase project-level/administrator-owned setting, then verify the GraphQL endpoint is inaccessible to anon and authenticated while REST/Auth still work.

### Leaked-password protection

Security Advisor reports auth_leaked_password_protection as disabled. The connected tools do not expose an Auth configuration mutation, so this has not been changed. An authorized project administrator must open [Supabase Auth Email settings](https://supabase.com/dashboard/project/nyhyoyjznbpilailccof/auth/providers?provider=Email), enable leaked-password protection, save, and rerun Security Advisor.

### SECURITY DEFINER advisor warning

The remaining 34-function warning is not itself proof of a vulnerability. It is still open because authenticated callers can execute these functions. Before merge, retain the per-function authorization review and test sensitive functions with insufficient permissions and out-of-scope warehouse IDs. Do not revoke all 34 indiscriminately: several are deliberate app RPCs and policy helpers.

## Visual browser test

Playwright Chromium runs against a temporary static HTTP server for the repository checkout in GitHub Actions; it does not create a second database or mutate stock. Screenshots are attached to the successful workflow run as the orshap-visual-smoke-screenshots artifact. The test covers Arabic/English login, RTL/LTR desktop layout, mobile layout, fixed mobile navigation, five mobile actions, page navigation, horizontal overflow, and uncaught page errors.

The visual review found and corrected one real UI defect: the mobile bottom navigation was visible on desktop. The CSS now hides it by default and the Playwright test asserts it is hidden at desktop width. The test also scrolls to the end of the mobile document and verifies the last content block can be reached above the fixed navigation while the topbar stays anchored.

## Historical merge gate (2026-10-24)

The initial review's PR #4 draft gate is retained only as historical context. The current release decision and unresolved blockers are recorded in the continuation audit below.

## Continuation audit — 2026-10-25 (latest live state)

### GitHub, CI and browser verification
- Merged PR #18 (settings boolean normalization), PR #19 (legacy shelf area selection), PR #42 (database-generated stock-movement references and retry), and PR #43 (correct dashboard New Request screenshot evidence).
- PR #42 and PR #43 both passed the WMS regression workflow and the syntax/visual workflow on their tested PR heads. The tested file contents are present on `main`. The GitHub connector returned no separate workflow runs/statuses for the squash merge commits themselves, so do not describe this as a distinct post-merge CI run.
- Playwright Chromium screenshots confirm the New Request form opens from both the dashboard and transactions page, and the stock-movement form remains open with a blank reference and retry action after the mocked reference RPC fails. The browser test intercepts transaction RPC writes; no inventory write is made by the browser smoke suite.
- Main no longer contains the browser-generated `MOV-${Date.now()}` reference fallback. Stock movement reference generation uses `next_transaction_reference`; failure leaves the form open and exposes retry.
- Main uses the canonical storage-area report filter. The current source has no `zone_id` or `section_id` references in `app.js`; legacy report RPCs were retired in migration `20261025102208`.

### Live Supabase transaction tests — same database, forced rollback
These were executed against the connected Supabase database inside explicit transactions/subtransactions. Each test raised a deliberate rollback sentinel after collecting its result. Read-only checks after each run confirmed no test transaction, stock, transfer, stocktake, or sync-log rows remained, and the baseline stock stayed at 99.

| Test | Observed result inside rollback transaction | Result |
|---|---|---|
| GRN create and approve | Generated reference; transaction APPROVED; stock rose 99→100; one inventory-ledger and one transaction-ledger row for the test batch | PASS |
| Duplicate transaction create/approval | Repeated create returned `already_created=true`; second approval was rejected as already approved; ledger row counts stayed at one each | PASS |
| Over-issue | Issue for 100 against stock 99 was rejected with `Insufficient stock`; balance stayed 99 | PASS |
| Competing issue requests | Two pending issues of 60 against 99: first approved to 39; second remained pending and was rejected for insufficient stock; only first had a transaction-ledger row | PASS for serialized posting invariant; **not a true simultaneous two-session race test** |
| Supplier return | Request did not change stock; replay returned `already_created=true`; approval reduced stock 99→97 and wrote one inventory-ledger row | PASS |
| Return from usage and return from customer | Each approval added one unit and one inventory-ledger row for its test batch | PASS |
| Inter-warehouse transfer, partial receipt, remainder return | Dispatch replay was idempotent; received 3 of 5; requested return of 2; return review ACCEPT and physical return confirmation completed; receipt replay returned `already_processed=true`; final test balances source 96 + destination 3 = total 99, and ledger balances matched | PASS |
| Stocktake cycle | Two lines populated and counted; submitted for review; a different reviewer approved; INCREASE settlement changed stock/ledger 99→100 and wrote one transaction-ledger row | PASS |
| Offline sync replay | First sync returned SUCCESS; same operation replay returned ALREADY_PROCESSED with payload conflict check verified; one stock row, transaction, line, inventory-ledger row, transaction-ledger row and sync-log row during test | PASS |
| Server-side warehouse scope | Active clerk with no assigned warehouses was denied creation in W1 with `No warehouse is assigned to this user` | PASS |
| Ambiguous supplier-return owner | A temporary second owner was introduced only inside the rollback savepoint; ownerless supplier return was rejected because two owners had sufficient quantity | PASS |

### Post-rollback database integrity
- `stock`: 1 row, quantity 99.
- `inventory_ledger`: 2 rows; stock-versus-ledger comparison across item/shelf/storage-area/owner/batch keys: 0 mismatches (1 key compared).
- `transaction_ledger`: 2 rows; arithmetic mismatches: 0.
- Approved transactions without an approved transaction-ledger entry: 0.
- Duplicate transaction references: 0.
- Stock rows with missing shelves: 0; shelf/storage-area/warehouse mismatches: 0.
- Current counts after rollback: 2 transactions, 2 transaction lines, 1 stock row, 2 inventory-ledger rows, 2 transaction-ledger rows, 0 stock transfers, 0 transfer orders, 0 stocktake sessions, and 0 sync-log rows.
- Temporary stocktake permission changes and the temporary second-owner row were also rolled back.

### SECURITY DEFINER review
- Current database inventory: 71 public `SECURITY DEFINER` functions; 33 executable by `authenticated`, 0 executable by `anon`. All 71 have a pinned `search_path`.
- For the 33 authenticated-executable functions, static definition checks found `auth.uid()` in all 33; permission-related terms in 27; active-user checks in 26; warehouse-scope terms in 22; and explicit row/advisory-lock terms in 16. These are keyword/structure indicators, not a substitute for semantic review of every function.
- The critical posting, transfer/return, stocktake settlement, and sync functions were inspected and exercised through rollback tests above. Duplicate approvals are blocked; transfer receipt replay is idempotent; sync replay is idempotent; over-issue is rejected. A true simultaneous two-session race test remains unexecuted because the available rollback harness cannot safely keep one production transaction committed while proving the competing session's result.
- Do not revoke all 33 functions in bulk. Some are deliberate application RPCs or helpers; continue reviewing any function not covered by the critical-flow tests individually.

### Security blockers still open
- **GraphQL ACL remains unresolved.** Live ACL inspection shows `graphql_public.graphql(text,text,jsonb,jsonb)` owned by managed role `supabase_admin`, with EXECUTE granted to PUBLIC, `anon`, and `authenticated`. The migration `20261025110500_orshap_verify_orphan_graphql_resolver_acl_live_v13958.sql` was attempted through the connected tool, but it correctly failed its owner check because the current role is `postgres`, is not a superuser, and is not a member of `supabase_admin`. The migration was not recorded as applied and ACLs remain unchanged. Disable `graphql_public` exposure through a supported Supabase project/API setting or apply the narrow REVOKE/GRANT as an authorized function owner, then re-check effective privileges and REST/RPC behavior.
- **Leaked-password protection remains disabled.** Security Advisor still reports `auth_leaked_password_protection`. The connected tools do not expose an Auth-settings mutation. An authorized administrator must enable leaked-password protection in Supabase Auth Email/Password security settings and rerun Security Advisor.
- The Security Advisor still reports 33 authenticated-callable `SECURITY DEFINER` functions. This count is a warning, not 33 proven vulnerabilities. Keep the remaining functions under per-function review.

### Release decision
**Not approved for production yet.** The live database posting, supplier/customer/usage returns, partial transfer and return, stocktake settlement, sync replay, over-issue rejection, owner ambiguity, and warehouse-scope tests passed with forced rollback and no residual test data. Stock and both ledgers reconcile. Production approval remains blocked by the unresolved GraphQL client-execution ACL and disabled leaked-password protection; a true simultaneous two-session over-issue test and separate CI execution on the exact squash merge commit also remain unverified.

## 2026-10-26 follow-up: offline queue and stocktake RPC ownership

- Added strict validation before replaying the offline master-data queue: only approved tables and insert/update/delete operations are accepted; malformed entries are retained for review rather than sent, and update payloads cannot alter primary keys.
- Tightened `public.save_stocktake_count(uuid,numeric)` in applied migration `20261026082014_orshap_stocktake_count_session_owner_guard_v13958`: the SECURITY DEFINER function now explicitly enforces the same stocktake creator-or-manager boundary as the table RLS policy, alongside the existing permission, session-state, and current warehouse-access checks.
- Tightened `public.populate_stocktake_session_lines(uuid)` and `public.submit_stocktake_for_review(uuid)` in applied migration `20261026082258_orshap_stocktake_mutation_session_owner_guards_v13958` for the same creator-or-manager boundary, and added explicit editable-session validation before populating lines.
- Read-only verification against the live database confirmed all three RPC definitions contain both the ownership guard and warehouse-scope guard. No stock movements, stocktake counts, settlement, or ledger rows were created by this audit.
- CI regression checks and desktop/mobile browser smoke tests passed on commit `b1f6f42dc802137419d201bf049375a1d72993f6`.

### Remaining release blockers

The prior blockers remain unchanged: the exposed `graphql_public.graphql` EXECUTE ACL requires an authorized owner or supported Supabase API setting to resolve, and leaked-password protection must be enabled in Supabase Auth settings. The Security Advisor also continues to report callable SECURITY DEFINER functions for per-function review; that warning alone does not prove each function is vulnerable.
