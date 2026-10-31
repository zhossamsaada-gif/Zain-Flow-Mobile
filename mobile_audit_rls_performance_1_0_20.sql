-- Keep the current row access conditions while evaluating auth.uid() once per statement.
alter policy mobile_stock_owner_insert on public.mobile_stock_operations
  with check (exists (
    select 1 from public.companies c
    where c.id = mobile_stock_operations.company_id
      and c.owner_id = (select auth.uid())
  ));

alter policy mobile_stock_owner_read on public.mobile_stock_operations
  using (exists (
    select 1 from public.companies c
    where c.id = mobile_stock_operations.company_id
      and c.owner_id = (select auth.uid())
  ));

alter policy profile_self_or_manager_select on public.user_profiles
  using (
    company_id = zain_private.current_company_id()
    and (
      auth_user_id = (select auth.uid())
      or zain_private.has_permission(company_id, 'manage_users'::text)
    )
  );

-- The member SELECT policy already includes stock managers with branch access.
-- Split the old ALL policy into its write actions, preserving write checks.
drop policy if exists stock_manager_change on public.branch_stock;

create policy stock_manager_insert on public.branch_stock
  for insert to authenticated
  with check (
    company_id = zain_private.current_company_id()
    and zain_private.can_access_branch(company_id, branch_id)
    and zain_private.has_permission(company_id, 'manage_stock'::text)
  );

create policy stock_manager_update on public.branch_stock
  for update to authenticated
  using (
    company_id = zain_private.current_company_id()
    and zain_private.can_access_branch(company_id, branch_id)
    and zain_private.has_permission(company_id, 'manage_stock'::text)
  )
  with check (
    company_id = zain_private.current_company_id()
    and zain_private.can_access_branch(company_id, branch_id)
    and zain_private.has_permission(company_id, 'manage_stock'::text)
  );

create policy stock_manager_delete on public.branch_stock
  for delete to authenticated
  using (
    company_id = zain_private.current_company_id()
    and zain_private.can_access_branch(company_id, branch_id)
    and zain_private.has_permission(company_id, 'manage_stock'::text)
  );
