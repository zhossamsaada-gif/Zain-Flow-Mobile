-- Zain Flow Mobile 1.0.13: indexes used by full/incremental sync and internal trigger hardening.
create index if not exists branch_stock_company_branch_updated_idx
  on public.branch_stock(company_id,branch_id,updated_at,id);

create index if not exists product_catalog_company_parent_idx
  on public.product_catalog(company_id,parent_id);

create index if not exists invoices_company_product_idx
  on public.invoices(company_id,product_id);

alter function public.track_product_delete() set search_path=pg_catalog;
alter function public.zainflow_touch_updated_at() set search_path=pg_catalog;
alter function public.clean_test_record(uuid) set search_path=pg_catalog;

revoke all on function public.products() from public,anon,authenticated;
revoke all on function public.rls_auto_enable() from public,anon,authenticated;
revoke all on function public.track_product_delete() from public,anon,authenticated;
