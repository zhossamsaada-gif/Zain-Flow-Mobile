create or replace function public.online_desktop_price_group(p_company uuid,p_request uuid,p_branch uuid,p_items jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare u uuid:=auth.uid();payload jsonb;old_payload jsonb;receipt jsonb;item jsonb;r jsonb;products jsonb:='[]';
begin
 if u is null or p_company is distinct from zain_private.current_company_id() or not zain_private.has_permission(p_company,'edit_product') or not zain_private.can_access_branch(p_company,p_branch) then raise exception 'PRODUCT_ACCESS_DENIED';end if;
 if p_request is null or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 500 then raise exception 'INVALID_PRICE_GROUP';end if;
 if exists(select 1 from jsonb_array_elements(p_items)x,jsonb_object_keys(x->'patch')k where k not in ('price','cost')) then raise exception 'INVALID_PRICE_FIELD';end if;
 payload:=jsonb_build_object('items',p_items,'branch',p_branch);
 insert into zain_private.online_write_receipts(company_id,actor_id,request_key,payload) values(p_company,u,p_request,payload) on conflict do nothing;
 select t.payload,t.result into old_payload,receipt from zain_private.online_write_receipts t where company_id=p_company and actor_id=u and request_key=p_request for update;
 if old_payload is distinct from payload then raise exception 'REQUEST_KEY_MISMATCH';end if;
 if receipt is not null then return receipt||jsonb_build_object('replayed',true);end if;
 perform id from public.product_catalog where company_id=p_company and id in(select (x->>'id')::uuid from jsonb_array_elements(p_items)x) order by id for update;
 for item in select value from jsonb_array_elements(p_items) loop
  r:=public.online_desktop_product(p_company,md5(p_request::text||':'||(item->>'id'))::uuid,p_branch,(item->>'id')::uuid,item->'expected',item->'patch',false);
  products:=products||jsonb_build_array(r->'product');
 end loop;
 receipt:=jsonb_build_object('request_key',p_request,'products',products,'replayed',false);
 update zain_private.online_write_receipts t set result=receipt where t.company_id=p_company and t.actor_id=u and t.request_key=p_request;
 return receipt;
end $$;
revoke all on function public.online_desktop_price_group(uuid,uuid,uuid,jsonb) from public,anon;
grant execute on function public.online_desktop_price_group(uuid,uuid,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
