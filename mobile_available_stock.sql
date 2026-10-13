CREATE OR REPLACE FUNCTION public.mobile_save_invoice(p_company_id uuid, p_kind text, p_batch_id uuid, p_request_key uuid, p_lines jsonb, p_party_id uuid, p_party_name text, p_invoice_date date, p_discount_amount numeric DEFAULT 0, p_paid numeric DEFAULT 0, p_payment_method text DEFAULT 'cash'::text, p_edit boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_uid uuid:=auth.uid(); v_existing jsonb; v_signature jsonb; v_result jsonb;
 v_gross numeric;v_net numeric;v_due numeric;v_main uuid;v_old_party uuid;
 v_old_gross numeric:=0;v_old_net numeric:=0;v_old_paid numeric:=0;v_old_adjust numeric:=0;
begin
 if v_uid is null or p_company_id is distinct from zain_private.current_company_id() then raise exception 'AUTH_REQUIRED'; end if;
 if p_kind is null or p_kind not in ('sale','purchase') or not zain_private.has_permission(p_company_id,p_kind) then raise exception 'INVOICE_PERMISSION_DENIED'; end if;
 if p_edit and not zain_private.has_permission(p_company_id,'edit_invoice') then raise exception 'INVOICE_EDIT_PERMISSION_DENIED'; end if;
 if p_batch_id is null or p_request_key is null or p_invoice_date is null or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 200 then raise exception 'INVALID_INVOICE'; end if;
 if p_payment_method is null or p_payment_method not in ('cash','transfer','card','vodafone','instapay','credit') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
 v_signature:=jsonb_build_object('company',p_company_id,'kind',p_kind,'batch',p_batch_id,'lines',p_lines,'party',p_party_id,'name',p_party_name,'date',p_invoice_date,'discount',p_discount_amount,'paid',p_paid,'method',p_payment_method,'edit',p_edit);
 insert into public.invoice_idempotency(company_id,actor_id,request_key) values(p_company_id,v_uid,p_request_key) on conflict do nothing;
 select result into v_existing from public.invoice_idempotency where company_id=p_company_id and actor_id=v_uid and request_key=p_request_key for update;
 if v_existing is not null then
   if v_existing->'mobile_signature' is distinct from v_signature then raise exception 'REQUEST_KEY_MISMATCH'; end if;
   return (v_existing-'mobile_signature')||jsonb_build_object('replayed',true);
 end if;
 select id into v_main from public.branches where company_id=p_company_id and is_main and active order by id limit 1;
 if v_main is null or not zain_private.can_access_branch(p_company_id,v_main) then raise exception 'MAIN_BRANCH_UNAVAILABLE'; end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x where (x->>'branch_id')::uuid is distinct from v_main or coalesce((x->>'qty')::numeric,0)<=0 or coalesce((x->>'unit_price')::numeric,-1)<0 or (x->>'qty')::numeric::text in ('NaN','Infinity','-Infinity') or (x->>'unit_price')::numeric::text in ('NaN','Infinity','-Infinity')) then raise exception 'INVALID_INVOICE_LINE'; end if;
 if exists(select 1 from jsonb_array_elements(p_lines) x join public.product_catalog c on c.parent_id=(x->>'product_id')::uuid and c.company_id=p_company_id) then raise exception 'SELECT_PRODUCT_COLOR'; end if;
 select round(sum((x->>'qty')::numeric*(x->>'unit_price')::numeric),2) into v_gross from jsonb_array_elements(p_lines) x;
 if p_discount_amount is null or p_paid is null or p_discount_amount::text in ('NaN','Infinity','-Infinity') or p_paid::text in ('NaN','Infinity','-Infinity') or round(p_discount_amount,2)<>p_discount_amount or p_discount_amount<0 or p_discount_amount>v_gross then raise exception 'INVALID_DISCOUNT'; end if;
 v_net:=round(v_gross-p_discount_amount,2);
 if p_paid<0 or p_paid>v_net or round(p_paid,2)<>p_paid then raise exception 'INVALID_PAID_AMOUNT'; end if;
 v_due:=v_net-p_paid;
 if p_party_id is null and (p_kind='purchase' or v_due>0) then raise exception 'SELECT_CUSTOMER_OR_SUPPLIER'; end if;
 if p_edit then
  perform 1 from public.invoices where company_id=p_company_id and coalesce(batch_id,id)=p_batch_id order by id for update;
  if exists(select 1 from public.invoices where company_id=p_company_id and coalesce(batch_id,id)=p_batch_id and branch_id is distinct from v_main) then raise exception 'INVOICE_BRANCH_MISMATCH'; end if;
  select max(party_id::text)::uuid,coalesce(sum(total),0),coalesce(max(final_total),sum(total),0),coalesce(sum(paid),0) into v_old_party,v_old_gross,v_old_net,v_old_paid from public.invoices where company_id=p_company_id and kind=p_kind and coalesce(batch_id,id)=p_batch_id;
  if p_kind='purchase' then v_old_adjust:=v_old_gross-greatest(0,v_old_net-v_old_paid); end if;
 end if;
 v_result:=public.save_invoice_atomic(p_company_id,p_kind,p_batch_id,p_request_key,p_lines,p_party_id,p_party_name,p_invoice_date,case when v_gross=0 then 0 else p_discount_amount/v_gross*100 end,p_paid,p_edit);
 -- Stock deduction is capped per product by save_invoice_atomic; invoice bills the full sold quantity.
 -- Desktop's endpoint treats purchases as gross debt; reconcile the agreed net debt atomically.
 if p_kind='purchase' then
   if v_old_party is not null and v_old_adjust<>0 then update public.contacts set balance=balance+v_old_adjust where id=v_old_party and company_id=p_company_id; end if;
   update public.contacts set balance=balance-((v_result->>'gross_total')::numeric-v_due) where id=p_party_id and company_id=p_company_id;
 elsif p_party_id is not null then
   update public.contacts set balance=balance+v_due-(v_result->>'due')::numeric where id=p_party_id and company_id=p_company_id;
 end if;
 update public.invoices set final_total=case when id=(select id from public.invoices where company_id=p_company_id and batch_id=p_batch_id and final_total is distinct from 0 order by created_at,id limit 1) then v_net else 0 end,payment_method=p_payment_method,source='mobile' where company_id=p_company_id and batch_id=p_batch_id;
 -- For a 100% discount all totals are zero already; no special header is required.
 v_result:=v_result||jsonb_build_object('final_total',v_net,'paid',p_paid,'due',v_due,'discount_amount',p_discount_amount,'payment_method',p_payment_method);
 update public.invoice_idempotency set result=v_result||jsonb_build_object('mobile_signature',v_signature) where company_id=p_company_id and actor_id=v_uid and request_key=p_request_key;
 return v_result;
end $function$

