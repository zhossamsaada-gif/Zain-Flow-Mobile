/* Camera-only module: it never reads or writes the catalog or Supabase. */
(() => {
  'use strict';
  const el = id => document.getElementById(id);
  let session = null, audio = null;
  const active = s => session === s && !s.stopped;
  const message = text => { el('scannerMessage').textContent = text; };
  function unlockSound() {
    try {
      const Audio = window.AudioContext || window.webkitAudioContext;
      if (!Audio) return;
      audio ||= new Audio();
      if (audio.state === 'suspended') audio.resume().catch(() => {});
      // Unlock audio during the original tap, including iOS Safari.
      const source = audio.createBufferSource();
      source.buffer = audio.createBuffer(1, 1, audio.sampleRate);
      source.connect(audio.destination); source.start();
    } catch {}
  }
  function beep() {
    try {
      if (audio?.state !== 'running') return;
      const oscillator = audio.createOscillator(), gain = audio.createGain();
      const now = audio.currentTime;
      oscillator.frequency.value = 1250;
      gain.gain.setValueAtTime(0.001, now);
      gain.gain.exponentialRampToValueAtTime(0.18, now + 0.012);
      gain.gain.exponentialRampToValueAtTime(0.001, now + 0.14);
      oscillator.connect(gain); gain.connect(audio.destination);
      oscillator.onended = () => { oscillator.disconnect(); gain.disconnect(); };
      oscillator.start(now); oscillator.stop(now + 0.15);
    } catch {}
    try { navigator.vibrate?.(60); } catch {}
  }
  function stopScanner() {
    const s = session; session = null;
    if (s) {
      s.stopped = true; clearTimeout(s.timer); clearTimeout(s.closeTimer);
      s.stream?.getTracks().forEach(track => track.stop());
      s.reader = null; s.hardReader = null;
    }
    const video = el('scannerVideo');
    video.pause(); video.srcObject = null;
    el('scannerModal').classList.add('hidden');
    el('scannerViewport').classList.remove('captured');
    el('scannerTorch').classList.add('hidden');
    el('scannerZoom').classList.add('hidden');
  }
  function accept(s, value) {
    if (!active(s) || s.done || typeof value !== 'string' || !value.length) return;
    // Two matching complete decodes reduce transient false readings; no numeric conversion.
    if (s.candidate !== value || performance.now() - s.candidateAt > 1200) {
      s.candidate = value; s.hits = 1; s.candidateAt = performance.now(); return;
    }
    if (++s.hits < 2) return;
    s.done = true;
    s.target.value = value;
    s.target.dispatchEvent(new Event('input', { bubbles: true }));
    s.target.dispatchEvent(new Event('change', { bubbles: true }));
    beep(); el('scannerViewport').classList.add('captured');
    message('تمت قراءة الباركود كاملًا ✓');
    // Release the camera immediately, keep the green confirmation visible briefly.
    s.stream.getTracks().forEach(track => track.stop());
    s.closeTimer = setTimeout(() => { if (active(s)) stopScanner(); }, 240);
  }
  async function scan(s) {
    if (!active(s) || s.done) return;
    const video = el('scannerVideo');
    try {
      if (video.readyState >= 2 && video.videoWidth) {
        s.attempt++;
        let found = false;
        if (s.detector) {
          try {
            const results = await s.detector.detect(video);
            if (!active(s)) return;
            // Prefer the barcode nearest the centre when several are visible.
            results.sort((a, b) => {
              const distance = r => r.boundingBox ? Math.hypot(r.boundingBox.x + r.boundingBox.width / 2 - video.videoWidth / 2, r.boundingBox.y + r.boundingBox.height / 2 - video.videoHeight / 2) : 0;
              return distance(a) - distance(b);
            });
            if (results[0]?.rawValue) { accept(s, results[0].rawValue); found = true; }
          } catch { s.detector = null; }
        }
        // The portable decoder covers browsers/formats without native detection.
        // Yield between attempts; never run simultaneous decodes or camera streams.
        if (!found && s.reader && (!s.detector || s.attempt % 3 === 0)) {
          const hard = s.attempt % 6 === 0, full = hard || s.attempt % 4 === 0;
          const sourceHeight = full ? video.videoHeight : Math.round(video.videoHeight * 0.65);
          const sourceY = (video.videoHeight - sourceHeight) / 2;
          const scale = Math.min(1, (hard ? 1920 : 1280) / video.videoWidth);
          s.canvas.width = Math.round(video.videoWidth * scale);
          s.canvas.height = Math.round(sourceHeight * scale);
          s.context.drawImage(video, 0, sourceY, video.videoWidth, sourceHeight, 0, 0, s.canvas.width, s.canvas.height);
          try { accept(s, (hard ? s.hardReader : s.reader).decodeFromCanvas(s.canvas).getText()); }
          catch {
            if (hard) {
              // Some camera luminance sources cannot rotate themselves. Rotate a full
              // frame explicitly so vertical 1D labels retain all digits and margins.
              s.rotatedCanvas.width = s.canvas.height;
              s.rotatedCanvas.height = s.canvas.width;
              const context = s.rotatedCanvas.getContext('2d', { willReadFrequently: true });
              context.translate(s.rotatedCanvas.width, 0); context.rotate(Math.PI / 2);
              context.drawImage(s.canvas, 0, 0);
              try { accept(s, s.hardReader.decodeFromCanvas(s.rotatedCanvas).getText()); } catch {}
            }
          }
        }
      }
    } catch {}
    if (active(s) && !s.done) s.timer = setTimeout(() => scan(s), s.detector ? 75 : 100);
  }
  async function configureTrack(s) {
    const track = s.stream.getVideoTracks()[0];
    s.track = track;
    let capabilities = {};
    try { capabilities = track.getCapabilities?.() || {}; } catch {}
    if (capabilities.focusMode?.includes('continuous')) {
      try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch {}
    }
    if (!active(s)) return;
    el('scannerTorch').classList.toggle('hidden', !capabilities.torch);
    el('scannerTorch').textContent = 'إضاءة'; el('scannerTorch').setAttribute('aria-pressed', 'false');
    s.torch = false; s.zoom = 1; s.capabilities = capabilities;
    el('scannerZoom').classList.toggle('hidden', !capabilities.zoom || capabilities.zoom.max <= 1);
    el('scannerZoom').textContent = 'تقريب 2×';
  }
  async function startScanner(target) {
    if (!target) return;
    stopScanner(); unlockSound();
    el('scannerModal').classList.remove('hidden');
    if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
      message('الكاميرا تحتاج رابط HTTPS أو localhost. افتح رابط التطبيق المنشور.'); return;
    }
    const s = { target, stopped: false, done: false, attempt: 0, candidate: '', hits: 0 };
    session = s; message('اسمح بالكاميرا. ضع الباركود كاملًا داخل الإطار مع ترك مسافة عند طرفيه.');
    try {
      if (window.ZXingBrowser?.BrowserMultiFormatReader) {
        s.reader = new window.ZXingBrowser.BrowserMultiFormatReader();
        // DecodeHintType.TRY_HARDER = 3 in the pinned ZXing dependency.
        s.hardReader = new window.ZXingBrowser.BrowserMultiFormatReader(new Map([[3, true]]));
        s.canvas = document.createElement('canvas');
        s.rotatedCanvas = document.createElement('canvas');
        s.context = s.canvas.getContext('2d', { willReadFrequently: true });
      }
      if (window.BarcodeDetector) {
        try {
          const formats = await window.BarcodeDetector.getSupportedFormats();
          if (!active(s)) return;
          if (formats.length) s.detector = new window.BarcodeDetector({ formats });
        } catch {}
      }
      if (!s.reader && !s.detector) throw new Error('تعذر تحميل قارئ الباركود. أعد تحميل التطبيق أثناء الاتصال بالإنترنت.');
      let stream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: 30, max: 30 } } });
      } catch (error) {
        if (!active(s)) return;
        if (!['OverconstrainedError', 'NotFoundError'].includes(error.name)) throw error;
        stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: true });
      }
      // Cancelling while the permission prompt is open must not leave a camera running.
      if (!active(s)) { stream.getTracks().forEach(track => track.stop()); return; }
      s.stream = stream;
      const video = el('scannerVideo'); video.srcObject = stream;
      await video.play(); if (!active(s)) return;
      await configureTrack(s); if (!active(s)) return;
      message('ضع الباركود كاملًا داخل الإطار، وثبّت الكاميرا. يمكن مسحه أفقيًا أو رأسيًا.');
      scan(s);
    } catch (error) {
      if (!active(s)) return;
      s.stream?.getTracks().forEach(track => track.stop());
      message(error.name === 'NotAllowedError' ? 'اسمح باستخدام الكاميرا من إعدادات المتصفح ثم أعد المحاولة.' : error.name === 'NotReadableError' ? 'الكاميرا مشغولة. أغلق التطبيق الآخر ثم أعد المحاولة.' : (error.message || 'تعذر تشغيل الكاميرا.'));
    }
  }
  async function cameraSetting(kind) {
    const s = session; if (!active(s) || s.done || s.setting || !s.track) return;
    s.setting = true;
    try {
      if (kind === 'torch') {
        const value = !s.torch;
        await s.track.applyConstraints({ advanced: [{ torch: value }] });
        if (!active(s)) return;
        s.torch = value; el('scannerTorch').textContent = value ? 'إطفاء الإضاءة' : 'إضاءة';
        el('scannerTorch').setAttribute('aria-pressed', String(value));
      } else {
        const limits = s.capabilities.zoom;
        const value = s.zoom > 1 ? Math.max(1, limits.min) : Math.min(2, limits.max);
        await s.track.applyConstraints({ advanced: [{ zoom: value }] });
        if (!active(s)) return;
        s.zoom = value; el('scannerZoom').textContent = value > 1 ? 'إلغاء التقريب' : 'تقريب 2×';
      }
    } catch { if (active(s)) message('هذا الإعداد غير متاح في الكاميرا الحالية. استمر بالمسح داخل الإطار.'); }
    finally { s.setting = false; }
  }
  el('scannerTorch').onclick = () => cameraSetting('torch');
  el('scannerZoom').onclick = () => cameraSetting('zoom');
  document.addEventListener('visibilitychange', () => { if (document.hidden) stopScanner(); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape') stopScanner(); });
  window.startScanner = startScanner;
  window.stopScanner = stopScanner;
})();
