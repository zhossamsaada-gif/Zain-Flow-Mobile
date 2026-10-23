-- شغّله مرة واحدة في Supabase SQL Editor الخاص بمشروع Zain Flow.
-- تسريع البحث الجزئي داخل اسم الصنف والكود والباركود.
create extension if not exists pg_trgm;
create index if not exists products_name_trgm_idx on public.products using gin (name gin_trgm_ops);
create index if not exists products_code_trgm_idx on public.products using gin (code gin_trgm_ops);
create index if not exists products_barcode_trgm_idx on public.products using gin (barcode gin_trgm_ops) where barcode is not null;

-- تمكين أحداث الإضافة والتعديل والحذف من خلال Supabase Realtime.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'product_catalog'
  ) then
    alter publication supabase_realtime add table public.product_catalog;
  end if;
end
$$;


-- مزامنة مخزون الفروع لحظيًا مع تطبيق الموبايل.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'branch_stock'
  ) then
    alter publication supabase_realtime add table public.branch_stock;
  end if;
end
$$;
