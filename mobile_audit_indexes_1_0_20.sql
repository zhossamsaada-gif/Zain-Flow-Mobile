-- Indexes for foreign-key lookups used by catalog, stock, invoices and review sessions.
-- These complement existing company-first indexes; they do not change application data.
create index if not exists branch_stock_product_id_idx
  on public.branch_stock (product_id);

create index if not exists invoices_product_id_fk_idx
  on public.invoices (product_id);

create index if not exists product_catalog_parent_id_fk_idx
  on public.product_catalog (parent_id);

create index if not exists companies_owner_id_fk_idx
  on public.companies (owner_id);

create index if not exists invoice_idempotency_actor_id_fk_idx
  on public.invoice_idempotency (actor_id);

create index if not exists account_payments_branch_id_fk_idx
  on public.account_payments (branch_id);

create index if not exists account_payments_contact_id_fk_idx
  on public.account_payments (contact_id);

create index if not exists depreciations_branch_id_fk_idx
  on public.depreciations (branch_id);

create index if not exists depreciations_company_id_fk_idx
  on public.depreciations (company_id);

create index if not exists expenses_branch_id_fk_idx
  on public.expenses (branch_id);

create index if not exists expenses_company_id_fk_idx
  on public.expenses (company_id);

create index if not exists mobile_stock_operations_branch_id_fk_idx
  on public.mobile_stock_operations (branch_id);

create index if not exists mobile_stock_operations_product_id_fk_idx
  on public.mobile_stock_operations (product_id);

create index if not exists product_catalog_branch_id_fk_idx
  on public.product_catalog (branch_id);

create index if not exists shifts_branch_id_fk_idx
  on public.shifts (branch_id);

create index if not exists stock_movements_branch_id_fk_idx
  on public.stock_movements (branch_id);

create index if not exists stock_movements_company_id_fk_idx
  on public.stock_movements (company_id);

create index if not exists stock_movements_product_id_fk_idx
  on public.stock_movements (product_id);

create index if not exists stock_transfers_from_branch_id_fk_idx
  on public.stock_transfers (from_branch_id);

create index if not exists stock_transfers_product_id_fk_idx
  on public.stock_transfers (product_id);

create index if not exists stock_transfers_to_branch_id_fk_idx
  on public.stock_transfers (to_branch_id);

create index if not exists user_profiles_auth_user_id_fk_idx
  on public.user_profiles (auth_user_id);

create index if not exists customer_change_log_company_id_fk_idx
  on zain_private.customer_change_log (company_id);

create index if not exists invoice_deletion_log_actor_id_fk_idx
  on zain_private.invoice_deletion_log (actor_id);

create index if not exists operation_idempotency_actor_id_fk_idx
  on zain_private.operation_idempotency (actor_id);

create index if not exists product_costs_company_id_fk_idx
  on zain_private.product_costs (company_id);

create index if not exists zain_review_accounts_company_id_fk_idx
  on zain_review_private.accounts (company_id);

-- Supabase already had an identical index for this relationship.
drop index if exists zain_review_private.zain_review_sessions_account_id_fk_idx;
