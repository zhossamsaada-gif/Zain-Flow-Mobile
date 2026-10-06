-- Atomic, owner-scoped product edit for the mobile catalog.
-- SECURITY INVOKER keeps existing table grants and RLS policies in force.
create or replace function public.mobile_update_product(
  p_product_id uuid,
  p_expected_name text,
  p_expected_price numeric,
  p_expected_cost numeric,
  p_expected_barcode text,
  p_new_name text,
  p_new_price numeric,
  p_new_cost numeric,
  p_new_barcode text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_product public.products%rowtype;
begin
  select c.id into v_company_id
  from public.companies as c
  where c.owner_id = (select auth.uid())
  limit 1;

  if v_company_id is null then
    raise exception 'PRODUCT_NOT_FOUND';
  end if;

  select p.* into v_product
  from public.products as p
  where p.id = p_product_id and p.company_id = v_company_id
  for update;

  if not found then
    raise exception 'PRODUCT_NOT_FOUND';
  end if;

  if v_product.name is distinct from p_expected_name
     or v_product.price is distinct from p_expected_price
     or v_product.cost is distinct from p_expected_cost
     or v_product.barcode is distinct from p_expected_barcode then
    raise exception 'PRODUCT_EDIT_CONFLICT';
  end if;

  -- Lock linked variants and update the parent plus eligible variants in one transaction.
  perform p.id
  from public.products as p
  where p.company_id = v_company_id and p.parent_id = p_product_id
  for update;

  update public.products
  set name = p_new_name,
      price = p_new_price,
      cost = p_new_cost,
      barcode = p_new_barcode,
      updated_at = now()
  where id = p_product_id and company_id = v_company_id;

  if v_product.parent_id is null then
    update public.products as child
    set name = case
          when left(child.name, length(v_product.name) + 1) = v_product.name || ' '
            then p_new_name || substring(child.name from length(v_product.name) + 1)
          else child.name
        end,
        price = case
          when child.price = v_product.price and child.cost = v_product.cost then p_new_price
          else child.price
        end,
        cost = case
          when child.price = v_product.price and child.cost = v_product.cost then p_new_cost
          else child.cost
        end,
        updated_at = now()
    where child.company_id = v_company_id
      and child.parent_id = p_product_id
      and (
        left(child.name, length(v_product.name) + 1) = v_product.name || ' '
        or (child.price = v_product.price and child.cost = v_product.cost)
      );
  end if;
end;
$$;

revoke all on function public.mobile_update_product(uuid, text, numeric, numeric, text, text, numeric, numeric, text) from public, anon;
grant execute on function public.mobile_update_product(uuid, text, numeric, numeric, text, text, numeric, numeric, text) to authenticated;
