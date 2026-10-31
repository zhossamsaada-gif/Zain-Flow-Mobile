# Zain Flow Mobile 1.0.20 audit and release

- Fixes the product editor initialization failure reported in the prior build.
- Keeps the existing catalog, invoice, barcode, color, and stock flows unchanged.
- Updates the shared-barcode client version and Service Worker cache key.
- `shared_barcode_mobile_1_0_20.sql` accepts the real Android app version while preserving authenticated registration, device-bound tokens, automatic approval, and the database write guard.
- `mobile_audit_indexes_1_0_20.sql` contains 27 targeted foreign-key indexes applied to the production project; these do not modify rows or relax RLS. An identical pre-existing review-session index was kept instead of duplicating it.
- `mobile_audit_rls_performance_1_0_20.sql` applies the same row access checks with lower per-row auth overhead and removes the overlapping stock-read policy without changing its effective access.
- Version: 1.0.20 / versionCode 21; application ID: `com.zainflow.catalogmobile`.
- APK stays signed with the same existing debug keystore to preserve sideload updates on devices using the prior APK.

## Security review note

Supabase's advisor reports `zain_review_login`, `zain_review_logout`, and `zain_review_read` because the custom review portal intentionally calls them without a Supabase Auth session. The functions use a password hash, throttling/temporary lockout, 256-bit random session tokens stored as SHA-256 hashes, an expiry, active-account checks, and a read-only section allowlist. Revoking anonymous execution would disable that portal. The warning is therefore documented rather than suppressed; moving that portal to an Edge Function or Supabase Auth is a separate migration.

The project also reports leaked-password protection disabled. This is an Auth setting outside the mobile app; it remains a security improvement to enable after verifying the account's password/reset flow. The remaining broad RLS/no-primary-key warnings mostly refer to intentionally private or dated backup schemas. No public table in the production schema was found without a primary key.

## Verification scope

The APK build, package metadata, embedded assets, JavaScript syntax, and the editor initialization scenarios were checked. A real invoice/stock write against production data was not used as a test, because that would change business records.
