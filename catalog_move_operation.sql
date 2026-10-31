CREATE OR REPLACE FUNCTION public.online_catalog_commit(p_company uuid, p_request uuid, p_operations jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
 with targets as (select coalesce(nullif(x->>'id',''),x->'row'->>'id',x->'args'->>'p_product_id')::uuid id from jsonb_array_elements(p_operations)x union select nullif(x->>'target_id','')::uuid from jsonb_array_elements(p_operations)x where x->>'action'='move'), roots as (select coalesce(p.parent_id,p.id) id from public.product_catalog p join targets t on t.id=p.id where p.company_id=p_company union select nullif(x->'row'->>'parent_id','')::uuid from jsonb_array_elements(p_operations)x)
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
  elsif op->>'action'='move' then
   v_id:=(op->>'id')::uuid;
   v_ids:=v_ids||zain_private.move_catalog_leaf(p_company,v_id,(op->>'target_id')::uuid,nullif(op->>'expected_parent','')::uuid,nullif(op->>'source_version','')::timestamptz,nullif(op->>'target_version','')::timestamptz,(op->>'new_group_id')::uuid);
  elsif op->>'action'='active' then
   v_id:=(op->>'id')::uuid;
   perform public.set_product_active(p_company,v_id,(op->>'active')::boolean);
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
end $function$

revoke all on function public.online_catalog_commit(uuid,uuid,jsonb) from public,anon;
grant execute on function public.online_catalog_commit(uuid,uuid,jsonb) to authenticated;
