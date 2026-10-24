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

## Merge gate

Keep PR #4 as Draft until:
1. The latest Playwright workflow passes after the desktop-nav fix.
2. GraphQL exposure is actually disabled or intentionally accepted with documented owner approval.
3. Leaked-password protection is enabled and rechecked.
4. The remaining SECURITY DEFINER warnings receive a documented accept/fix decision.
