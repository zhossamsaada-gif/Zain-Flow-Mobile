-- Main branch only. Atomic compare-and-set; each successful operation is recorded once.
create table if not exists public.mobile_stock_operations(
 id uuid primary key,company_id uuid not null references public.companies(id) on delete cascade,
 product_id uuid not null references public.product_catalog(id) on delete cascade,
 branch_id uuid not null references public.branches(id) on delete cascade,
 expected_qty numeric not null,new_qty numeric not null,created_at timestamptz not null default now()
);
create index if not exists mobile_stock_operations_company_idx on public.mobile_stock_operations(company_id);
alter table public.mobile_stock_operations enable row level security;
drop policy if exists mobile_stock_owner_read on public.mobile_stock_operations;
create policy mobile_stock_owner_read on public.mobile_stock_operations for select to authenticated using(exists(select 1 from public.companies c where c.id=company_id and c.owner_id=auth.uid()));
drop policy if exists mobile_stock_owner_insert on public.mobile_stock_operations;
create policy mobile_stock_owner_insert on public.mobile_stock_operations for insert to authenticated with check(exists(select 1 from public.companies c where c.id=company_id and c.owner_id=auth.uid()));
revoke all on public.mobile_stock_operations from public,anon,authenticated;
grant select,insert on public.mobile_stock_operations to authenticated;
create or replace function public.mobile_update_stock(
 p_operation_id uuid, p_product_id uuid, p_branch_id uuid,
 p_expected_qty numeric, p_expected_updated_at timestamptz, p_new_qty numeric
) returns numeric language plpgsql security invoker set search_path = '' as $$
declare
 v_company uuid; v_product public.products%rowtype;
 v_stock public.branch_stock%rowtype; v_parent uuid; v_total numeric;
begin
 select id into v_company from public.companies where owner_id=auth.uid() limit 1;
 if v_company is null or not exists(select 1 from public.branches where id=p_branch_id and company_id=v_company and is_main and active) then
  raise exception 'STOCK_ACCESS_DENIED';
 end if;
 if p_operation_id is null or p_new_qty is null or p_new_qty < 0 or p_new_qty::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_STOCK_QUANTITY'; end if;
 -- This branch lock serializes mobile adjustments and parent aggregation.
 perform id from public.branches where id=p_branch_id for update;
 if exists(select 1 from public.mobile_stock_operations where id=p_operation_id and company_id=v_company and product_id=p_product_id and branch_id=p_branch_id and new_qty=p_new_qty and expected_qty=p_expected_qty) then
  select qty into v_total from public.branch_stock where branch_id=p_branch_id and product_id=p_product_id and company_id=v_company;
  return v_total;
 end if;
 select * into v_product from public.products where id=p_product_id and company_id=v_company;
 if not found then raise exception 'PRODUCT_NOT_FOUND'; end if;
 if exists(select 1 from public.products where parent_id=p_product_id and company_id=v_company) then raise exception 'STOCK_EDIT_VARIANTS'; end if;
 select * into v_stock from public.branch_stock where branch_id=p_branch_id and product_id=p_product_id and company_id=v_company for update;
 if found then
  if v_stock.qty is distinct from p_expected_qty or (p_expected_updated_at is not null and v_stock.updated_at is distinct from p_expected_updated_at) then raise exception 'STOCK_EDIT_CONFLICT'; end if;
 else
  v_total:=case when v_product.branch_id is null or v_product.branch_id=p_branch_id then coalesce(v_product.qty,0) else 0 end;
  if v_total is distinct from p_expected_qty then raise exception 'STOCK_EDIT_CONFLICT'; end if;
  insert into public.branch_stock(company_id,branch_id,product_id,qty) values(v_company,p_branch_id,p_product_id,v_total) on conflict(branch_id,product_id) do nothing;
  select * into v_stock from public.branch_stock where branch_id=p_branch_id and product_id=p_product_id and company_id=v_company for update;
  if v_stock.qty is distinct from p_expected_qty then raise exception 'STOCK_EDIT_CONFLICT'; end if;
 end if;
 -- Reuse Desktop's existing atomic stock engine, permissions, and movement history.
 if p_new_qty <> p_expected_qty then
  perform public.adjust_stock_atomic(v_company,p_branch_id,p_product_id,p_new_qty-p_expected_qty,'adjustment',p_operation_id,'تعديل مخزون الفرع الرئيسي من الموبايل');
 end if;
 v_parent:=v_product.parent_id;
 if v_parent is not null then
  select coalesce(sum(coalesce(bs.qty,case when p.branch_id is null or p.branch_id=p_branch_id then p.qty else 0 end,0)),0) into v_total from public.products p left join public.branch_stock bs on bs.product_id=p.id and bs.branch_id=p_branch_id and bs.company_id=v_company where p.parent_id=v_parent and p.company_id=v_company;
  insert into public.branch_stock(company_id,branch_id,product_id,qty) values(v_company,p_branch_id,v_parent,v_total) on conflict(branch_id,product_id) do update set qty=excluded.qty,updated_at=clock_timestamp();
  update public.products set qty=v_total,updated_at=clock_timestamp() where id=v_parent and company_id=v_company;
 end if;
 insert into public.mobile_stock_operations(id,company_id,branch_id,product_id,expected_qty,new_qty) values(p_operation_id,v_company,p_branch_id,p_product_id,p_expected_qty,p_new_qty);
 return p_new_qty;
end;$$;
revoke all on function public.mobile_update_stock(uuid,uuid,uuid,numeric,timestamptz,numeric) from public,anon;
grant execute on function public.mobile_update_stock(uuid,uuid,uuid,numeric,timestamptz,numeric) to authenticated;
