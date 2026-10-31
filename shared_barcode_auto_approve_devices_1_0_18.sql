-- Automatically approve any device that registers with an authorized account.
-- Requires authenticated owner/active member access and a device-specific token.
-- The shared barcode write guard remains enabled.
begin;

create or replace function public.shared_barcode_register(
  p_company uuid,
  p_device uuid,
  p_protocol integer,
  p_version text,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  digest text;
begin
  if auth.uid() is null
     or p_company is null
     or p_device is null
     or p_protocol is distinct from 1
     or p_version is null
     or p_version not in ('2.2.29-shared-v1', '1.0.18')
     or p_token is null
     or p_token !~ '^[a-f0-9]{64}$' then
    raise exception 'INVALID_DEVICE';
  end if;

  if not exists (
       select 1 from public.companies
       where id = p_company and owner_id = auth.uid()
     )
     and not exists (
       select 1 from public.user_profiles
       where company_id = p_company and auth_user_id = auth.uid() and active
     ) then
    raise exception 'DEVICE_ACCESS_DENIED';
  end if;

  digest := encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  insert into zain_private.shared_barcode_devices
    (company_id, device_id, actor_id, token_hash, protocol, app_version)
  values
    (p_company, p_device, auth.uid(), digest, p_protocol, p_version)
  on conflict do nothing;

  if not exists (
    select 1 from zain_private.shared_barcode_devices
    where company_id = p_company
      and device_id = p_device
      and actor_id = auth.uid()
      and token_hash = digest
      and protocol = p_protocol
      and app_version = p_version
  ) then
    raise exception 'DEVICE_IDENTITY_CONFLICT';
  end if;

  update zain_private.shared_barcode_devices
  set approved = true
  where company_id = p_company
    and device_id = p_device
    and actor_id = auth.uid()
    and token_hash = digest
    and protocol = p_protocol
    and app_version = p_version;

  return jsonb_build_object('registered', true, 'protocol', p_protocol, 'app_version', p_version, 'approved', true);
end
$function$;

revoke all on function public.shared_barcode_register(uuid, uuid, integer, text, text) from public, anon;
grant execute on function public.shared_barcode_register(uuid, uuid, integer, text, text) to authenticated;

commit;
