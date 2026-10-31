-- Zain Flow Mobile 1.0.13: keep the products view company-scoped without owner-level view execution.
grant select on zain_private.product_costs to authenticated;

drop policy if exists product_costs_member_select on zain_private.product_costs;
create policy product_costs_member_select
on zain_private.product_costs
for select
to authenticated
using (company_id = (select zain_private.current_company_id()));

alter view public.products set (security_invoker=true);
