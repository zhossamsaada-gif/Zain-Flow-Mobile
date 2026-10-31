# Mobile 1.0.21 — live product and stock alignment

- Treat rows with `deleted_at` or `purged_at` as non-live when counting variants, displaying nested products, calculating parent stock, editing parent barcodes, or checking related product IDs.
- When a product has no live variants, show and edit its own main-branch stock even if deleted historical variants remain in Supabase.
- This matches desktop lifecycle rules and does not alter product or invoice data.
- Supabase compatibility migration: `shared_barcode_mobile_1_0_21.sql` (prepared only; not applied to production).

## Verification

- Parsed the inline application script and all six shipped JavaScript files.
- Checked the regression case for a live root with a deleted former variant: root stock remains 19.9833; an active variant still aggregates variant stock.
