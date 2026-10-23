create or replace function zain_private.move_catalog_leaf(p_company uuid,p_source uuid,p_target uuid,p_expected_parent uuid,p_source_version timestamptz,p_target_version timestamptz,p_group uuid)
returns uuid[] language plpgsql security invoker set search_path='pg_catalog' as $fn$
declare s public.product_catalog%rowtype;t public.product_catalog%rowtype;v_root uuid;v_main uuid;v_parent uuid;v_branch record;v_qty numeric;
begin
 if auth.uid() is null or p_company is distinct from zain_private.current_company_id() or not zain_private.has_permission(p_company,'edit_product') then raise exception 'AUTH_REQUIRED';end if;
 if p_source is null or p_target is null or p_source=p_target then raise exception 'INVALID_MOVE';end if;
 select * into s from public.product_catalog where company_id=p_company and id=p_source;
 if not found then raise exception 'INVALID_MOVE_SOURCE';end if;
 select * into t from public.product_catalog where company_id=p_company and id=p_target;
 if not found or t.parent_id is not null or t.active=false or s.active=false then raise exception 'INVALID_MOVE_TARGET';end if;
 if exists(select 1 from public.product_catalog where company_id=p_company and parent_id=p_source) then raise exception 'INVALID_MOVE_GROUP';end if;
 if s.parent_id is distinct from p_expected_parent or (p_source_version is not null and s.updated_at is distinct from p_source_version) or (p_target_version is not null and t.updated_at is distinct from p_target_version) then raise exception 'PRODUCT_EDIT_CONFLICT';end if;
 if s.parent_id=p_target then raise exception 'INVALID_MOVE_SAME_PARENT';end if;
 if (select count(*) from public.branches where company_id=p_company and active and is_main)<>1 then raise exception 'INVALID_MAIN_BRANCH';end if;
 select id into v_main from public.branches where company_id=p_company and active and is_main;
 if not zain_private.can_access_branch(p_company,v_main) then raise exception 'AUTH_REQUIRED';end if;
 v_root:=p_target;
 if not exists(select 1 from public.product_catalog where company_id=p_company and parent_id=p_target) then
  if p_group is null then raise exception 'INVALID_MOVE_GROUP_ID';end if;
  insert into public.products(id,company_id,code,name,unit,qty,cost,price,reorder,barcode,branch_id,category,supplier)
  select p_group,p_company,'ZF-GROUP-'||p_group::text,t.name,t.unit,0,p.cost,p.price,t.reorder,null,v_main,t.category,t.supplier from public.products p where p.id=p_target and p.company_id=p_company;
  v_root:=p_group;
  update public.product_catalog set parent_id=v_root,updated_at=clock_timestamp() where id=p_target and company_id=p_company;
 end if;
 update public.product_catalog set parent_id=v_root,updated_at=clock_timestamp() where id=p_source and company_id=p_company;
 for v_parent in select distinct x from unnest(array[v_root,s.parent_id])x where x is not null loop
  for v_branch in select id from public.branches where company_id=p_company order by id loop
   select coalesce(sum(coalesce(bs.qty,case when v_branch.id=v_main then p.qty else 0 end,0)),0) into v_qty
   from public.product_catalog p left join public.branch_stock bs on bs.company_id=p_company and bs.branch_id=v_branch.id and bs.product_id=p.id where p.company_id=p_company and p.parent_id=v_parent;
   insert into public.branch_stock(company_id,branch_id,product_id,qty) values(p_company,v_branch.id,v_parent,v_qty)
   on conflict(branch_id,product_id) do update set qty=excluded.qty,updated_at=clock_timestamp();
   if v_branch.id=v_main then update public.product_catalog set qty=v_qty,updated_at=clock_timestamp() where id=v_parent and company_id=p_company;end if;
  end loop;
 end loop;
 return array[p_source,p_target,v_root,s.parent_id];
end $fn$;
revoke all on function zain_private.move_catalog_leaf(uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid) from public,anon,authenticated;
