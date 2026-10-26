-- Restore authenticated table privileges for administrative department management.
-- RLS remains the authorization boundary; only users passing the existing
-- administrative_departments_manager_* policies can mutate rows.
GRANT INSERT, UPDATE, DELETE ON TABLE public.administrative_departments TO authenticated;
