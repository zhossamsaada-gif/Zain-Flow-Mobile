# Shared barcode compatibility — mobile 1.0.18

The production registration RPC accepts the real Android version `1.0.18`, protocol `1`, and registers a device identity/token.

Applied migrations:
- `mobile_shared_barcode_compatibility_1_0_18`
- `shared_barcode_auto_approve_authenticated_devices`

An authenticated owner or active company account now auto-approves its own newly registered device. Login, company access, token identity checks, Supabase permissions, and the shared barcode write guard remain required. Shared barcode creation still depends on the existing account setting and the app's explicit duplicate-sharing confirmation.
