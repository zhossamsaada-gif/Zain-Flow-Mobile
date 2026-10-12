-- Retain invoice validation, billing, permissions and receipts. Lock catalog families first,
-- then keep the displayed parent stock consistent after sales/purchases of colors.
do $$ declare definition text;begin
 select pg_get_functiondef(oid) into definition from pg_proc where proname='save_invoice_atomic' and pronamespace='public'::regnamespace;
 if position('-- Online stock family guard' in definition)>0 then return;end if;
 if position('-- Lock the affected products and stock rows in deterministic order.' in definition)=0 or position('  if v_old_party is not null then' in definition)=0 then raise exception 'Invoice function changed; inspect before patching';end if;
 definition:=replace(definition,'  -- Lock the affected products and stock rows in deterministic order.',$patch$
  -- Online stock family guard: catalog rows before any stock rows.
  perform p.id from public.product_catalog p where p.company_id=p_company_id and (p.id in (
   select coalesce(c.parent_id,c.id) from public.product_catalog c where c.company_id=p_company_id and c.id in (
    select (x->>'product_id')::uuid from jsonb_array_elements(v_lines)x union select product_id from public.invoices where p_edit and company_id=p_company_id and kind=p_kind and coalesce(batch_id,id)=p_batch_id))
   or p.parent_id in (select coalesce(c.parent_id,c.id) from public.product_catalog c where c.company_id=p_company_id and c.id in (
    select (x->>'product_id')::uuid from jsonb_array_elements(v_lines)x union select product_id from public.invoices where p_edit and company_id=p_company_id and kind=p_kind and coalesce(batch_id,id)=p_batch_id))) order by p.id for update;
  -- Lock the affected products and stock rows in deterministic order.
$patch$);
 definition:=replace(definition,'  if v_old_party is not null then',$patch$
  for v_product in select distinct c.parent_id as parent_id from public.product_catalog c where c.company_id=p_company_id and c.parent_id is not null and c.id in (
   select (x->>'product_id')::uuid from jsonb_array_elements(v_lines)x union select product_id from public.invoices where p_edit and company_id=p_company_id and kind=p_kind and coalesce(batch_id,id)=p_batch_id) order by c.parent_id loop
   select coalesce(sum(coalesce(bs.qty,case when v_branch=v_main_branch then child.qty else 0 end,0)),0) into v_req from public.product_catalog child left join public.branch_stock bs on bs.product_id=child.id and bs.branch_id=v_branch and bs.company_id=p_company_id where child.company_id=p_company_id and child.parent_id=v_product.parent_id;
   insert into public.branch_stock(company_id,branch_id,product_id,qty) values(p_company_id,v_branch,v_product.parent_id,v_req) on conflict(branch_id,product_id) do update set qty=excluded.qty,updated_at=clock_timestamp();
   if v_branch=v_main_branch then update public.product_catalog set qty=v_req,updated_at=clock_timestamp() where company_id=p_company_id and id=v_product.parent_id;end if;
  end loop;
  if v_old_party is not null then
$patch$);
 execute definition;
end $$;
notify pgrst,'reload schema';
