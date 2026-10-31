/* Shared barcode client identity, registration, and duplicate safeguards. */
(() => {
  'use strict';

  const PROTOCOL = 1;
  // Must match the Android versionName in android/app/build.gradle.
  const APP_VERSION = '1.0.21';
  const KEY_PREFIX = 'zf-shared-barcode-device-v1:';
  let identity = null;
  let cachedStatus = null;
  let cachedAt = 0;

  function randomHex(bytes = 32) {
    if (!globalThis.crypto?.getRandomValues) throw Error('الجهاز لا يدعم إنشاء هوية آمنة.');
    const values = new Uint8Array(bytes);
    crypto.getRandomValues(values);
    return [...values].map(x => x.toString(16).padStart(2, '0')).join('');
  }

  function uuid() {
    if (globalThis.crypto?.randomUUID) return crypto.randomUUID();
    const b = new Uint8Array(16);
    crypto.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }

  function setContext(companyId, userId) {
    if (!companyId || !userId) { identity = null; cachedStatus = null; return null; }
    const key = KEY_PREFIX + companyId + ':' + userId;
    try {
      let saved = JSON.parse(localStorage.getItem(key) || 'null');
      if (!saved || !/^[0-9a-f-]{36}$/i.test(saved.deviceId || '') || !/^[a-f0-9]{64}$/.test(saved.token || '')) {
        saved = { deviceId: uuid(), token: randomHex() };
        localStorage.setItem(key, JSON.stringify(saved));
      }
      identity = { ...saved, companyId, userId };
      cachedStatus = null;
      cachedAt = 0;
      return identity.deviceId;
    } catch (e) {
      identity = null;
      cachedStatus = null;
      throw Error('تعذر حفظ هوية هذا الجهاز محليًا: ' + (e?.message || e));
    }
  }

  function headersFor(url, baseHeaders) {
    const headers = new Headers(baseHeaders || undefined);
    if (identity && String(url || '').startsWith('https://fohsjmudarzcasaoneqf.supabase.co/rest/v1/')) {
      headers.set('x-zf-device-id', identity.deviceId);
      headers.set('x-zf-device-token', identity.token);
    }
    return headers;
  }

  function userMessage(error) {
    const raw = String(error?.message || error || '');
    if (/SHARED_BARCODE_CLIENT_UPGRADE_REQUIRED|DEVICE_NOT_REGISTERED|INVALID_DEVICE|PGRST202/.test(raw)) {
      return 'قاعدة البيانات تحتاج تحديث توافق الموبايل (SQL المرفق) قبل اعتماد هذا الجهاز. لم يتم حفظ التعديل.';
    }
    if (/DEVICE_IDENTITY_CONFLICT/.test(raw)) return 'هوية الجهاز محفوظة بشكل مختلف على الخادم. لا تمسح بيانات التطبيق؛ أرسل معرف الجهاز للدعم.';
    if (/DEVICE_LIMIT_REACHED/.test(raw)) return 'وصل النشاط إلى الحد الأقصى للأجهزة المعتمدة. أزل اعتماد جهاز قديم ثم أعد المحاولة.';
    if (/DEVICE_ACCESS_DENIED|AUTH_REQUIRED|JWT/.test(raw)) return 'لا يملك الحساب الحالي صلاحية تسجيل هذا الجهاز؛ سجّل الدخول بحساب مالك النشاط.';
    return raw;
  }

  function typedError(message, code) { return Object.assign(new Error(message), { code, sharedBarcodeGate: true }); }

  async function registerAndCheck(client, companyId, userId, deadline = p => p) {
    if (!identity || identity.companyId !== companyId || identity.userId !== userId) setContext(companyId, userId);
    if (!identity) throw typedError('تعذر إنشاء هوية الجهاز.', 'SHARED_BARCODE_CLIENT_UPGRADE_REQUIRED');
    if (cachedStatus && Date.now() - cachedAt < 5 * 60 * 1000) return cachedStatus;
    const registration = await deadline(client.rpc('shared_barcode_register', {
      p_company: companyId,
      p_device: identity.deviceId,
      p_protocol: PROTOCOL,
      p_version: APP_VERSION,
      p_token: identity.token
    }));
    if (registration.error) throw typedError(userMessage(registration.error), registration.error.code || 'SHARED_BARCODE_CLIENT_UPGRADE_REQUIRED');
    if (!registration.data?.registered) throw typedError('لم يؤكد الخادم تسجيل الجهاز؛ لم يتم حفظ التعديل.', 'SHARED_BARCODE_CLIENT_UPGRADE_REQUIRED');
    const response = await deadline(client.rpc('shared_barcode_status', { p_company: companyId, p_device: identity.deviceId }));
    if (response.error) throw typedError(userMessage(response.error), response.error.code || 'SHARED_BARCODE_CLIENT_UPGRADE_REQUIRED');
    const status = response.data;
    if (!status || status.device_id !== identity.deviceId || status.company_id !== companyId) throw typedError('بيانات اعتماد الجهاز غير مطابقة؛ لم يتم حفظ التعديل.', 'SHARED_BARCODE_CLIENT_UPGRADE_REQUIRED');
    cachedStatus = status;
    cachedAt = Date.now();
    return status;
  }

  async function approve(client, companyId, deadline = p => p) {
    if (!identity || identity.companyId !== companyId) throw typedError('سجّل الدخول مجددًا لتسجيل هذا الجهاز.', 'DEVICE_NOT_REGISTERED');
    const result = await deadline(client.rpc('shared_barcode_approve_device', { p_company: companyId, p_device: identity.deviceId }));
    if (result.error) throw typedError(userMessage(result.error), result.error.code || 'DEVICE_NOT_REGISTERED');
    cachedStatus = null;
    cachedAt = 0;
    return result.data;
  }

  function status() { return cachedStatus; }
  function deviceId() { return identity?.deviceId || null; }
  function appVersion() { return APP_VERSION; }
  function protocol() { return PROTOCOL; }
  function clearStatus() { cachedStatus = null; cachedAt = 0; }

  window.ZFSharedBarcode = { setContext, headersFor, registerAndCheck, approve, status, deviceId, appVersion, protocol, userMessage, clearStatus };
})();
