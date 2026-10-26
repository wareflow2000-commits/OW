-- Restrict the assigned-warehouse scope helper to authenticated application sessions.
-- The function returns authorization information and is used by RLS policies/triggers.
REVOKE ALL ON FUNCTION public.current_user_can_access_warehouse(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_user_can_access_warehouse(uuid) TO authenticated, service_role;
