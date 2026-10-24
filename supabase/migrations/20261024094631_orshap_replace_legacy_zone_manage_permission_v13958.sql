-- Replace the legacy zone/section management permission with facility management.
-- This migration changes authorization semantics only; it does not mutate inventory or transaction data.

insert into public.permissions(key, description)
values ('action:facility:manage', 'Manage warehouses, storage areas, shelves and facility structure')
on conflict (key) do update
set description = excluded.description;

insert into public.role_permissions(id, role_name, permission_key)
select gen_random_uuid(), old.role_name, 'action:facility:manage'
from public.role_permissions old
where old.permission_key = 'action:zone:manage'
  and not exists (
    select 1
    from public.role_permissions current_grant
    where current_grant.role_name = old.role_name
      and current_grant.permission_key = 'action:facility:manage'
  );

do $migration$
declare
  policy_row record;
  using_expr text;
  check_expr text;
  role_list text;
begin
  for policy_row in
    select schemaname, tablename, policyname, cmd, roles, qual, with_check, permissive
    from pg_policies
    where schemaname = 'public'
      and (
        coalesce(qual, '') like '%action:zone:manage%'
        or coalesce(with_check, '') like '%action:zone:manage%'
      )
  loop
    using_expr := case
      when policy_row.qual is null then null
      else replace(policy_row.qual, 'action:zone:manage', 'action:facility:manage')
    end;
    check_expr := case
      when policy_row.with_check is null then null
      else replace(policy_row.with_check, 'action:zone:manage', 'action:facility:manage')
    end;
    role_list := array_to_string(policy_row.roles, ',');
    execute format('drop policy %I on %I.%I',
      policy_row.policyname, policy_row.schemaname, policy_row.tablename);
    execute format(
      'create policy %I on %I.%I as %s for %s to %s%s%s',
      policy_row.policyname, policy_row.schemaname, policy_row.tablename,
      lower(policy_row.permissive), policy_row.cmd, role_list,
      case
        when using_expr is not null and policy_row.cmd in ('SELECT','DELETE','UPDATE','ALL')
        then format(' using (%s)', using_expr) else ''
      end,
      case
        when check_expr is not null and policy_row.cmd in ('INSERT','UPDATE','ALL')
        then format(' with check (%s)', check_expr) else ''
      end
    );
  end loop;
end
$migration$;

delete from public.role_permissions old
where old.permission_key = 'action:zone:manage'
  and exists (
    select 1 from public.role_permissions current_grant
    where current_grant.role_name = old.role_name
      and current_grant.permission_key = 'action:facility:manage'
  );

delete from public.permissions
where key = 'action:zone:manage'
  and not exists (
    select 1 from public.role_permissions old
    where old.permission_key = 'action:zone:manage'
  );
