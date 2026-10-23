create or replace function public.online_desktop_product(p_company uuid,p_request uuid,p_branch uuid,p_product uuid,p_expected jsonb,p_patch jsonb,p_insert boolean default false)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid();payload jsonb;old_payload jsonb;receipt jsonb;current_row jsonb;merged jsonb;p public.product_catalog%rowtype;cost numeric;k text;
begin
 if u is null or p_company is distinct from zain_private.current_company_id() or not zain_private.has_permission(p_company,'edit_product') or not zain_private.can_access_branch(p_company,p_branch) then raise exception 'PRODUCT_ACCESS_DENIED';end if;
 if p_request is null or p_product is null or jsonb_typeof(p_patch) is distinct from 'object' then raise exception 'INVALID_PRODUCT';end if;
 if exists(select 1 from jsonb_object_keys(p_patch) x where x not in ('company_id','code','name','unit','cost','price','reorder','barcode','category','supplier','extra_units','parent_id')) then raise exception 'INVALID_PRODUCT_FIELD';end if;
 if p_patch?'cost' and not zain_private.has_permission(p_company,'view_cost') then raise exception 'COST_ACCESS_DENIED';end if;
 payload:=jsonb_build_object('product',p_product,'branch',p_branch,'expected',p_expected,'patch',p_patch,'insert',p_insert);
 insert into zain_private.online_write_receipts(company_id,actor_id,request_key,payload) values(p_company,u,p_request,payload) on conflict do nothing;
 select r.payload,r.result into old_payload,receipt from zain_private.online_write_receipts r where company_id=p_company and actor_id=u and request_key=p_request for update;
 if old_payload is distinct from payload then raise exception 'REQUEST_KEY_MISMATCH';end if;
 if receipt is not null then return receipt||jsonb_build_object('replayed',true);end if;
 select to_jsonb(v) into current_row from public.products v where v.company_id=p_company and v.id=p_product;
 if not p_insert then
  perform id from public.product_catalog where company_id=p_company and id=p_product for update;
  select to_jsonb(v) into current_row from public.products v where v.company_id=p_company and v.id=p_product;
  if current_row is null then raise exception 'PRODUCT_NOT_FOUND';end if;
  for k in select jsonb_object_keys(coalesce(p_expected,'{}')) loop if current_row->k is distinct from p_expected->k then raise exception 'PRODUCT_EDIT_CONFLICT';end if;end loop;
 elsif current_row is not null then raise exception 'PRODUCT_ALREADY_EXISTS';end if;
 merged:=coalesce(current_row,'{}')||p_patch||jsonb_build_object('id',p_product,'company_id',p_company);
 if coalesce(length(btrim(merged->>'name')),0)=0 or coalesce(length(btrim(merged->>'code')),0)=0 or coalesce((merged->>'price')::numeric,0)<0 or coalesce((merged->>'cost')::numeric,0)<0 or (merged->>'price')::numeric::text in ('NaN','Infinity','-Infinity') or (merged->>'cost')::numeric::text in ('NaN','Infinity','-Infinity') then raise exception 'INVALID_PRODUCT';end if;
 if nullif(merged->>'parent_id','') is not null and not exists(select 1 from public.product_catalog where id=(merged->>'parent_id')::uuid and company_id=p_company and parent_id is null) then raise exception 'INVALID_PARENT';end if;
 p:=jsonb_populate_record(null::public.product_catalog,merged);
 if p_insert then
  insert into public.product_catalog(id,company_id,code,name,unit,qty,price,reorder,barcode,category,supplier,extra_units,parent_id,active,branch_id)
  values(p_product,p_company,p.code,p.name,coalesce(p.unit,'قطعة'),0,coalesce(p.price,0),coalesce(p.reorder,5),p.barcode,p.category,p.supplier,p.extra_units,p.parent_id,true,p_branch);
  insert into zain_private.product_costs(product_id,company_id,cost) values(p_product,p_company,coalesce((merged->>'cost')::numeric,0));
 else
  update public.product_catalog set code=p.code,name=p.name,unit=p.unit,price=p.price,reorder=p.reorder,barcode=p.barcode,category=p.category,supplier=p.supplier,extra_units=p.extra_units,parent_id=p.parent_id,updated_at=clock_timestamp() where company_id=p_company and id=p_product;
  if p_patch?'cost' then update zain_private.product_costs set cost=(p_patch->>'cost')::numeric,updated_at=clock_timestamp() where product_id=p_product and company_id=p_company;end if;
 end if;
 select to_jsonb(v) into current_row from public.products v where v.company_id=p_company and v.id=p_product;
 receipt:=jsonb_build_object('request_key',p_request,'product',current_row,'replayed',false);
 update zain_private.online_write_receipts r set result=receipt where r.company_id=p_company and r.actor_id=u and r.request_key=p_request;
 return receipt;
end $$;
revoke all on function public.online_desktop_product(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.online_desktop_product(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean) to authenticated;
notify pgrst,'reload schema';
