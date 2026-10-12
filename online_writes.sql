-- Stable receipts are internal. Authenticated callers only access scoped RPCs.
create table if not exists zain_private.online_write_receipts(
 company_id uuid not null,actor_id uuid not null,request_key uuid not null,
 payload jsonb not null,result jsonb,created_at timestamptz not null default now(),
 primary key(company_id,actor_id,request_key));
alter table zain_private.online_write_receipts enable row level security;
revoke all on zain_private.online_write_receipts from public,anon,authenticated;

create or replace function public.online_catalog_commit(p_company uuid,p_request uuid,p_operations jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare v_uid uuid:=auth.uid();v_old jsonb;v_result jsonb;v_payload jsonb;op jsonb;r jsonb;a jsonb;v_id uuid;v_main uuid;v_ids uuid[]:=array[]::uuid[];
begin
 if v_uid is null or p_company is distinct from zain_private.current_company_id() or not exists(select 1 from public.companies where id=p_company and owner_id=v_uid) then raise exception 'AUTH_REQUIRED';end if;
 if p_request is null or jsonb_typeof(p_operations) is distinct from 'array' or jsonb_array_length(p_operations) not between 1 and 100 then raise exception 'INVALID_REQUEST';end if;
 v_payload:=jsonb_build_object('operations',p_operations);
 insert into zain_private.online_write_receipts(company_id,actor_id,request_key,payload) values(p_company,v_uid,p_request,v_payload) on conflict do nothing;
 select result,payload into v_old,v_result from zain_private.online_write_receipts where company_id=p_company and actor_id=v_uid and request_key=p_request for update;
 if v_result is distinct from v_payload then raise exception 'REQUEST_KEY_MISMATCH';end if;
 if v_old is not null then return v_old||jsonb_build_object('replayed',true);end if;
 select id into v_main from public.branches where company_id=p_company and is_main and active order by id limit 1;
 -- Same order as the invoice engine: catalog rows before stock rows.
 with targets as (select coalesce(nullif(x->>'id',''),x->'row'->>'id',x->'args'->>'p_product_id')::uuid id from jsonb_array_elements(p_operations)x), roots as (select coalesce(p.parent_id,p.id) id from public.product_catalog p join targets t on t.id=p.id where p.company_id=p_company union select nullif(x->'row'->>'parent_id','')::uuid from jsonb_array_elements(p_operations)x)
 select array_agg(distinct id) into v_ids from roots;
 perform id from public.product_catalog where company_id=p_company and (id=any(v_ids) or parent_id=any(v_ids)) order by id for update;
 v_ids:=array[]::uuid[];
 for op in select value from jsonb_array_elements(p_operations) loop
  if op->>'action'='insert' then
   r:=op->'row';v_id:=(r->>'id')::uuid;
   if r->>'company_id' is distinct from p_company::text or v_id is null or coalesce(length(btrim(r->>'name')),0)=0 or coalesce((r->>'price')::numeric,-1)<0 or coalesce((r->>'cost')::numeric,-1)<0 or (r->>'price')::numeric::text in ('NaN','Infinity','-Infinity') or (r->>'cost')::numeric::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_PRODUCT';end if;
   if nullif(r->>'parent_id','') is not null and not exists(select 1 from public.product_catalog where id=(r->>'parent_id')::uuid and company_id=p_company and parent_id is null) then raise exception 'INVALID_PARENT';end if;
   insert into public.products(id,company_id,code,name,unit,qty,cost,price,reorder,barcode,parent_id,branch_id,category,supplier)
   values(v_id,p_company,r->>'code',r->>'name',coalesce(r->>'unit','قطعة'),0,(r->>'cost')::numeric,(r->>'price')::numeric,coalesce((r->>'reorder')::numeric,5),nullif(r->>'barcode',''),nullif(r->>'parent_id','')::uuid,v_main,r->>'category',r->>'supplier');
  elsif op->>'action'='update' then
   a:=op->'args';v_id:=(a->>'p_product_id')::uuid;
   if coalesce(length(btrim(a->>'p_new_name')),0)=0 or coalesce((a->>'p_new_price')::numeric,-1)<0 or coalesce((a->>'p_new_cost')::numeric,-1)<0 or (a->>'p_new_price')::numeric::text in ('NaN','Infinity','-Infinity') or (a->>'p_new_cost')::numeric::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_PRODUCT';end if;
   perform public.mobile_update_product(v_id,a->>'p_expected_name',(a->>'p_expected_price')::numeric,(a->>'p_expected_cost')::numeric,a->>'p_expected_barcode',a->>'p_new_name',(a->>'p_new_price')::numeric,(a->>'p_new_cost')::numeric,a->>'p_new_barcode');
  elsif op->>'action'='stock' then
   a:=op->'args';v_id:=(a->>'p_product_id')::uuid;
   perform public.mobile_update_stock((a->>'p_operation_id')::uuid,v_id,(a->>'p_branch_id')::uuid,(a->>'p_expected_qty')::numeric,(a->>'p_expected_updated_at')::timestamptz,(a->>'p_new_qty')::numeric);
  elsif op->>'action'='delete' then
   v_id:=(op->>'id')::uuid;
   if exists(select 1 from public.invoices where company_id=p_company and product_id in(select id from public.product_catalog where company_id=p_company and (id=v_id or parent_id=v_id))) then raise exception 'PRODUCT_HAS_INVOICES';end if;
   delete from public.products where company_id=p_company and id=v_id;
  else raise exception 'INVALID_ACTION';end if;
  v_ids:=array_append(v_ids,v_id);
 end loop;
 v_result:=jsonb_build_object('request_key',p_request,'product_ids',to_jsonb(v_ids),'replayed',false);
 update zain_private.online_write_receipts set result=v_result where company_id=p_company and actor_id=v_uid and request_key=p_request;
 return v_result;
end $$;
revoke all on function public.online_catalog_commit(uuid,uuid,jsonb) from public,anon;
grant execute on function public.online_catalog_commit(uuid,uuid,jsonb) to authenticated;

-- Retain the existing stock RPC signature and receipt history, correcting lock order.
do $$ declare definition text;begin
 select pg_get_functiondef(p.oid) into definition from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='mobile_update_stock';
 if definition is null then raise exception 'Missing mobile_update_stock';end if;
 definition:=replace(definition,'perform id from public.branches where id=p_branch_id for update;','');
 definition:=replace(definition,'select * into v_product from public.products where id=p_product_id and company_id=v_company;','perform id from public.product_catalog where company_id=v_company and (id=p_product_id or id=(select parent_id from public.product_catalog where id=p_product_id and company_id=v_company) or parent_id=coalesce((select parent_id from public.product_catalog where id=p_product_id and company_id=v_company),p_product_id)) order by id for update; select * into v_product from public.products where id=p_product_id and company_id=v_company for update;');
 execute definition;
end $$;
notify pgrst,'reload schema';

-- Desktop stock changes use the shared movement engine, branch grants and stable receipts.
create or replace function public.online_set_branch_stock(p_company uuid,p_request uuid,p_product uuid,p_branch uuid,p_expected numeric,p_qty numeric)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid();payload jsonb;old_payload jsonb;v_receipt jsonb;p public.product_catalog%rowtype;stock public.branch_stock%rowtype;main uuid;root uuid;total numeric;before_qty numeric;
begin
 if u is null or p_company is distinct from zain_private.current_company_id() or not zain_private.has_permission(p_company,'manage_stock') or not zain_private.can_access_branch(p_company,p_branch) then raise exception 'STOCK_ACCESS_DENIED';end if;
 if p_request is null or p_qty is null or p_expected is null or p_qty<0 or p_qty::text in ('NaN','Infinity','-Infinity') or p_expected::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_STOCK_QUANTITY';end if;
 payload:=jsonb_build_object('product',p_product,'branch',p_branch,'expected',p_expected,'qty',p_qty);
 insert into zain_private.online_write_receipts(company_id,actor_id,request_key,payload) values(p_company,u,p_request,payload) on conflict do nothing;
 select r.payload,r.result into old_payload,v_receipt from zain_private.online_write_receipts r where company_id=p_company and actor_id=u and request_key=p_request for update;
 if old_payload is distinct from payload then raise exception 'REQUEST_KEY_MISMATCH';end if;
 if v_receipt is not null then return v_receipt||jsonb_build_object('replayed',true);end if;
 select coalesce(parent_id,id) into root from public.product_catalog where company_id=p_company and id=p_product;
 if root is null then raise exception 'PRODUCT_NOT_FOUND';end if;
 perform id from public.product_catalog where company_id=p_company and (id=root or parent_id=root) order by id for update;
 select * into p from public.product_catalog where company_id=p_company and id=p_product;
 select id into main from public.branches where company_id=p_company and is_main order by id limit 1;
 select * into stock from public.branch_stock where company_id=p_company and branch_id=p_branch and product_id=p_product for update;
 before_qty:=coalesce(stock.qty,case when p_branch=main then p.qty else 0 end,0);
 if before_qty is distinct from p_expected then raise exception 'STOCK_EDIT_CONFLICT';end if;
 if exists(select 1 from public.product_catalog where company_id=p_company and parent_id=p_product) then
  select coalesce(sum(coalesce(bs.qty,case when p_branch=main then c.qty else 0 end,0)),0) into total from public.product_catalog c left join public.branch_stock bs on bs.product_id=c.id and bs.branch_id=p_branch and bs.company_id=p_company where c.company_id=p_company and c.parent_id=p_product;
  if total is distinct from p_qty then raise exception 'STOCK_EDIT_VARIANTS';end if;
  insert into public.branch_stock(company_id,branch_id,product_id,qty) values(p_company,p_branch,p_product,total) on conflict(branch_id,product_id) do update set qty=excluded.qty,updated_at=clock_timestamp();
  if p_branch=main then update public.product_catalog set qty=total,updated_at=clock_timestamp() where id=p_product;end if;
 elsif p_qty<>before_qty then
  perform public.adjust_stock_atomic(p_company,p_branch,p_product,p_qty-before_qty,'adjustment',p_request,'تعديل مخزون مؤكد من الكمبيوتر');
 end if;
 if p.parent_id is not null then
  select coalesce(sum(coalesce(bs.qty,case when p_branch=main then c.qty else 0 end,0)),0) into total from public.product_catalog c left join public.branch_stock bs on bs.product_id=c.id and bs.branch_id=p_branch and bs.company_id=p_company where c.company_id=p_company and c.parent_id=p.parent_id;
  insert into public.branch_stock(company_id,branch_id,product_id,qty) values(p_company,p_branch,p.parent_id,total) on conflict(branch_id,product_id) do update set qty=excluded.qty,updated_at=clock_timestamp();
  if p_branch=main then update public.product_catalog set qty=total,updated_at=clock_timestamp() where id=p.parent_id;end if;
 end if;
 v_receipt:=jsonb_build_object('request_key',p_request,'product_id',p_product,'qty',p_qty,'replayed',false);
 update zain_private.online_write_receipts r set result=v_receipt where r.company_id=p_company and r.actor_id=u and r.request_key=p_request;
 return v_receipt;
end $$;
revoke all on function public.online_set_branch_stock(uuid,uuid,uuid,uuid,numeric,numeric) from public,anon;
grant execute on function public.online_set_branch_stock(uuid,uuid,uuid,uuid,numeric,numeric) to authenticated;
notify pgrst,'reload schema';
