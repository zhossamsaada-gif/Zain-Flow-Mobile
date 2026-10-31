# Shared barcode compatibility — mobile 1.0.17

The mobile client now sends the actual native `versionName` (`1.0.17`) and protocol `1` to the shared barcode registration RPC. It persists a per-installation device UUID and 256-bit token locally, sends them as `x-zf-device-id` / `x-zf-device-token` on Supabase REST requests, and checks server registration/approval before saving.

The server currently accepts only `2.2.29-shared-v1`, while the shared barcode account is enabled and has two approved devices. The mobile compatibility SQL is in `shared_barcode_mobile_1.0.17.sql`. It has **not** been applied. Review and approve it before applying it to production.

After the SQL is applied and the updated app is installed:

1. Open the app online and sign in with the Zain Flow owner account.
2. The app registers this installation. If it is not approved, tap **اعتماد هذا الجهاز** and confirm.
3. Product edits, stock changes, and invoice writes continue through the current guarded RPCs. A shared barcode still requires the form option and a second explicit confirmation.

The SQL preserves the existing shared barcode account flags and existing approvals. The new approval RPC only approves the authenticated owner's own registered mobile device, leaves all other devices unchanged, and does not enable shared barcode creation.
