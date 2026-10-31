-- Allow Zain Flow Mobile 1.0.21 device registration.
-- Keep protocol 1, existing desktop/mobile versions, authenticated account access,
-- device-bound tokens, automatic approval, and the shared-barcode write guard.
begin;

create or replace function public.shared_barcode_register(
 p_company uuid,p_device uuid,p_protocol integer,p_version text,p_token text
) returns jsonb language plpgsql security definer set search_path to 'pg_catalog' as $function$
declare digest text;
begin
 if auth.uid() is null or p_company is null or p_device is null or p_protocol is distinct from 1
    or p_version is null or p_version not in ('2.2.29-shared-v1','1.0.18','1.0.19','1.0.20','1.0.21')
    or p_token is null or p_token !~ '^[a-f0-9]{64}$' then raise exception 'INVALID_DEVICE'; end if;
 if not exists(select 1 from public.companies where id=p_company and owner_id=auth.uid())
    and not exists(select 1 from public.user_profiles where company_id=p_company and auth_user_id=auth.uid() and active)
 then raise exception 'DEVICE_ACCESS_DENIED'; end if;
 digest:=encode(sha256(convert_to(p_token,'UTF8')),'hex');
 insert into zain_private.shared_barcode_devices(company_id,device_id,actor_id,token_hash,protocol,app_version)
 values(p_company,p_device,auth.uid(),digest,p_protocol,p_version) on conflict do nothing;
 if not exists(select 1 from zain_private.shared_barcode_devices where company_id=p_company and device_id=p_device
   and actor_id=auth.uid() and token_hash=digest and protocol=p_protocol and app_version=p_version)
 then raise exception 'DEVICE_IDENTITY_CONFLICT'; end if;
 update zain_private.shared_barcode_devices set approved=true where company_id=p_company and device_id=p_device
   and actor_id=auth.uid() and token_hash=digest and protocol=p_protocol and app_version=p_version;
 return jsonb_build_object('registered',true,'protocol',p_protocol,'app_version',p_version,'approved',true);
end
$function$;
revoke all on function public.shared_barcode_register(uuid,uuid,integer,text,text) from public,anon;
grant execute on function public.shared_barcode_register(uuid,uuid,integer,text,text) to authenticated;

create or replace function public.shared_barcode_approve_device(p_company uuid,p_device uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog' as $function$
declare h jsonb:=coalesce(nullif(current_setting('request.headers',true),''),'{}'::jsonb);
begin
 if auth.uid() is null or not exists(select 1 from public.companies where id=p_company and owner_id=auth.uid())
 then raise exception 'OWNER_REQUIRED'; end if;
 if p_device is null or p_device::text is distinct from h->>'x-zf-device-id' then raise exception 'DEVICE_IDENTITY_MISMATCH'; end if;
 perform 1 from zain_private.shared_barcode_devices d where d.company_id=p_company and d.device_id=p_device
   and d.actor_id=auth.uid() and d.token_hash=encode(sha256(convert_to(coalesce(h->>'x-zf-device-token',''),'UTF8')),'hex')
   and d.protocol=1 and d.app_version in ('1.0.18','1.0.19','1.0.20','1.0.21') for update;
 if not found then raise exception 'DEVICE_NOT_REGISTERED'; end if;
 update zain_private.shared_barcode_devices set approved=true where company_id=p_company and device_id=p_device and actor_id=auth.uid();
 return jsonb_build_object('approved',true,'device_id',p_device);
end
$function$;
revoke all on function public.shared_barcode_approve_device(uuid,uuid) from public,anon;
grant execute on function public.shared_barcode_approve_device(uuid,uuid) to authenticated;
commit;
