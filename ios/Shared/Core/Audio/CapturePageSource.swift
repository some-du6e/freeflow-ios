import Foundation

/// The hidden capture page: its JavaScript, its HTML, and the constants the native side
/// shares with it.
///
/// The scripts live here as Swift strings rather than bundled .js files, so the app and the
/// keyboard always load exactly the code the macOS tests run in JavaScriptCore, and no
/// resource has to be copied into either bundle. The page is assembled as one inline script
/// under a CSP that allows nothing else, and is loaded with `baseURL`, a fake https origin
/// that makes it a secure context for getUserMedia.
enum CapturePageSource {
    /// The page's origin. `.invalid` never resolves, and the CSP blocks every fetch.
    static let host = "capture.freeflow.invalid"
    static let baseURL = URL(string: "https://capture.freeflow.invalid/")!
    /// The `WKScriptMessageHandlerWithReply` name the page posts to.
    static let messageHandlerName = "ffCapture"
    /// Matches `ffCapture.version` and the `v` field of the page's `ready` message.
    static let pageVersion = 1
    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'"
    /// App Group defaults key (DESIGN 5.2): in DEBUG builds only, true makes WebAudioCapture
    /// feed the synthetic tone through the page instead of the microphone.
    static let syntheticCaptureDefaultsKey = "ios_debug_synthetic_capture"

    /// The page's single script: ff-dsp.js, then ff-synthetic.js when included, then
    /// ff-capture.js, one per line block.
    static func script(includeSyntheticSource: Bool) -> String {
        let parts = includeSyntheticSource
            ? [dspScript, syntheticScript, captureScript]
            : [dspScript, captureScript]
        return parts.joined(separator: "\n") + "\n"
    }

    /// The page HTML. Release builds leave out the synthetic tone source.
    static func html(includeSyntheticSource: Bool) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        </head><body><script>
        \(script(includeSyntheticSource: includeSyntheticSource))</script></body></html>
        """
    }

    /// ff-dsp.js: the Kaiser polyphase resampler to 16 kHz, Int16 conversion and base64.
    static let dspScript = #"""
'use strict';
// ff-dsp.js: the capture page's DSP. It touches no DOM, so JavaScriptCore tests load it as is.
const FF_OUT_RATE = 16000;
function ffError(name) { const error = new Error(name); error.name = name; return error; }
function ffGcd(a, b) { while (b) { const t = a % b; a = b; b = t; } return a; }
function ffI0(x) { let s = 1, t = 1; const q = x * x / 4; for (let k = 1; k < 200 && t > 1e-12 * s; k++) { t *= q / (k * k); s += t; } return s; }
// Streaming rational polyphase resampler with a Kaiser-windowed sinc. For 16 kHz output it is
// flat to 7.0 kHz with a 70 dB stopband from 8.0 kHz, the output Nyquist, so speech above
// 8 kHz can't fold back down (WebKit's own 32-tap resampler and box averaging both let it).
class FFResampler {
  constructor(inRate, outRate = FF_OUT_RATE, attenDB = 70) {
    inRate = Math.round(inRate);
    if (!(inRate >= 1000 && inRate <= 384000)) throw ffError('UnsupportedRateError');
    const g = ffGcd(inRate, outRate);
    this.L = outRate / g; this.M = inRate / g; this.copy = inRate === outRate;
    if (this.copy) return;
    if (this.L > 640) throw ffError('UnsupportedRateError');
    const L = this.L, nyq = Math.min(inRate, outRate) / 2, df = nyq / 8, fs = inRate * L;
    const fc = (nyq - df / 2) / fs, beta = 0.1102 * (attenDB - 8.7);
    const T = this.T = Math.ceil(((attenDB - 7.95) / (14.36 * df / fs) + 1) / L);
    const N = T * L, mid = (N - 1) / 2, i0b = ffI0(beta);
    const bank = this.bank = new Float32Array(N); // bank[p * T + j] = L * h[p + j * L]
    for (let n = 0; n < N; n++) {
      const x = n - mid, r = 2 * n / (N - 1) - 1;
      const sinc = x === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * x) / (Math.PI * x);
      bank[(n % L) * T + Math.floor(n / L)] = L * sinc * ffI0(beta * Math.sqrt(Math.max(0, 1 - r * r))) / i0b;
    }
    this.hist = new Float32Array(T - 1); this.m = 0; this.seen = 0;
  }
  process(x) {
    if (this.copy) return Float32Array.from(x);
    const { L, M, T, bank } = this, H = T - 1;
    const buf = new Float32Array(H + x.length); buf.set(this.hist); buf.set(x, H);
    const base = this.seen - H, last = this.seen + x.length - 1;
    const out = new Float32Array(Math.ceil(x.length * L / M) + 2);
    let k = 0, m = this.m;
    for (;;) {
      const t = m * M, i = Math.floor(t / L);
      if (i > last) break;
      const off = (t - i * L) * T; let acc = 0;
      for (let j = 0, idx = i - base; j < T; j++, idx--) acc += bank[off + j] * buf[idx];
      out[k++] = acc; m++;
    }
    this.m = m; this.seen += x.length; this.hist = buf.slice(buf.length - H);
    return out.subarray(0, k);
  }
  // Pushes zeros through the filter so the last real samples come out.
  flush() { return this.copy ? new Float32Array(0) : this.process(new Float32Array(Math.ceil(this.T / 2) + 1)); }
}
// Float to Int16 exactly like PCM16.sample(fromUnit:) in Swift.
function ffToInt16(y) {
  const pcm = new Int16Array(y.length);
  for (let i = 0; i < y.length; i++) { const v = y[i] < -1 ? -1 : (y[i] > 1 ? 1 : y[i]); pcm[i] = Math.round(v * 32767); }
  return pcm;
}
const FF_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
// Uses the native Uint8Array.prototype.toBase64 where it exists (Safari 18.2+).
function ffBase64(u8) {
  if (typeof u8.toBase64 === 'function') return u8.toBase64();
  let s = '', i = 0; const r = u8.length % 3, end = u8.length - r;
  for (; i < end; i += 3) { const v = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2]; s += FF_B64[v >> 18] + FF_B64[(v >> 12) & 63] + FF_B64[(v >> 6) & 63] + FF_B64[v & 63]; }
  if (r === 1) { const v = u8[i] << 16; s += FF_B64[v >> 18] + FF_B64[(v >> 12) & 63] + '=='; }
  else if (r === 2) { const v = (u8[i] << 16) | (u8[i + 1] << 8); s += FF_B64[v >> 18] + FF_B64[(v >> 12) & 63] + FF_B64[(v >> 6) & 63] + '='; }
  return s;
}
"""#

    /// ff-synthetic.js: the DEBUG-only 440 Hz test tone that can stand in for the microphone.
    static let syntheticScript = #"""
'use strict';
// ff-synthetic.js: DEBUG builds only. A timer-driven 440 Hz test tone that stands in for the
// microphone, so the page, bridge, WAV writer and gain stage can be tested where Web Audio
// can't run. It repeats 0.3 s at -23 dBFS RMS and 0.2 s at -63 dBFS, at a 48 kHz device rate.
function ffSyntheticSource(onBlock) {
  const RATE = 48000, FRAMES = 2048, HZ = 440, CYCLE = 24000, LOUD_FRAMES = 14400;
  const LOUD = 0.1, QUIET = 0.001, MAX_BLOCKS_PER_TICK = 12;
  let made = 0, startedAt = 0, timer = 0, running = false;
  function block() {
    const x = new Float32Array(FRAMES);
    for (let i = 0; i < FRAMES; i++, made++) {
      const amplitude = made % CYCLE < LOUD_FRAMES ? LOUD : QUIET;
      x[i] = amplitude * Math.sin(2 * Math.PI * HZ * (made % RATE) / RATE);
    }
    return x;
  }
  // Emits every block whose start time has passed, like a device delivering on schedule.
  function pump() {
    const due = (performance.now() - startedAt) * RATE / 1000;
    for (let k = 0; running && k < MAX_BLOCKS_PER_TICK && made <= due; k++) onBlock(block());
  }
  return {
    rate: RATE,
    start() { running = true; startedAt = performance.now(); pump(); timer = setInterval(pump, 20); },
    stop() { running = false; clearInterval(timer); },
  };
}
"""#

    /// ff-capture.js: getUserMedia, the audio graph, chunking, acks and stop handling.
    static let captureScript = #"""
'use strict';
// ff-capture.js: page glue between Web Audio and the native WebAudioCapture. It follows
// ff-dsp.js (and ff-synthetic.js in DEBUG builds) in the page's one inline script.
//
// Native calls ffCapture.start({sid, synthetic, echoCancellation}), stop(sid) and cancel(sid).
// The page posts {t:'ready'}, then per session {t:'started'}, one {t:'pcm'} per callback,
// and finally {t:'ended'} or {t:'failed'}. Native acks every pcm message. The page releases
// the microphone by itself when posted chunks go unacked for 2.5 s (native-unresponsive) or
// when no audio callback arrives for 2.5 s (no-audio).
(() => {
  const SP_FRAMES = 2048;              // about 42.7 ms per ScriptProcessor callback at 48 kHz
  const METER_SECONDS = 1024 / 48000;  // about 21.3 ms RMS blocks for the waveform
  const ACK_TIMEOUT_MS = 2500;         // the dead-man switch, also the longest input stall
  const ACK_CHECK_MS = 500;
  const STOP_GRACE_MS = 250;           // longest wait for one more callback after stop()
  const native = window.webkit.messageHandlers.ffCapture;
  const post = (message) => native.postMessage(message); // a Promise, settled by the native reply
  let S = null;    // the active session
  let last = null; // the latest session, for status()

  const named = (name) => { const error = new Error(name); error.name = name; return error; };
  const errorName = (error) => (error && typeof error.name === 'string' && error.name) || 'Error';
  const matches = (s, sid) => sid === undefined || s.sid === Number(sid);

  function teardown(s) {
    clearInterval(s.watchdog);
    clearTimeout(s.stopTimer);
    if (s.source) s.source.stop();
    if (s.sp) { s.sp.onaudioprocess = null; s.sp.disconnect(); }
    if (s.src) s.src.disconnect();
    if (s.stream) s.stream.getTracks().forEach((track) => track.stop());
    if (s.ctx) { s.ctx.onstatechange = null; s.ctx.close().catch(() => {}); }
    if (s.audioSession) { try { navigator.audioSession.type = 'auto'; } catch (_) {} }
  }
  function end(s, reason) {
    if (S !== s) return;
    S = null; s.endedIn = s.phase; s.phase = 'ended'; s.reason = reason;
    teardown(s);
    post({ t: 'ended', sid: s.sid, reason, frames: s.frames }).catch(() => {});
  }
  function fail(s, name) {
    if (S !== s) return;
    S = null; s.endedIn = s.phase; s.phase = 'failed'; s.reason = name;
    teardown(s);
    post({ t: 'failed', sid: s.sid, name }).catch(() => {});
  }
  function send(s, y, levels, final) {
    const pcm = ffToInt16(y);
    const seq = s.seq++;
    s.frames += pcm.length;
    post({ t: 'pcm', sid: s.sid, seq, n: pcm.length, b64: ffBase64(new Uint8Array(pcm.buffer)), lv: levels, final })
      .then(() => { s.lastAck = performance.now(); s.acked = seq + 1; }, () => end(s, 'bridge-lost'));
  }
  function meter(s, x) {
    const levels = [];
    for (let i = 0; i < x.length; i++) {
      s.sumSq += x[i] * x[i];
      if (++s.count === s.meterFrames) { levels.push(Math.sqrt(s.sumSq / s.count)); s.sumSq = 0; s.count = 0; }
    }
    return levels;
  }
  function onAudio(s, x) {
    if (S !== s) return;
    s.callbacks++;
    s.lastAudio = performance.now();
    const levels = meter(s, x);
    const y = s.rs.process(x);
    if (s.stopping) finish(s, y, levels); else send(s, y, levels, false);
  }
  // Sends the last audio with the resampler's tail, then ends the session.
  function finish(s, y, levels) {
    const tail = s.rs.flush();
    const z = new Float32Array(y.length + tail.length);
    z.set(y); z.set(tail, y.length);
    send(s, z, levels, true);
    end(s, 'stopped');
  }
  function begin(s, rate, captureRate) {
    s.rs = new FFResampler(rate);
    s.meterFrames = Math.max(1, Math.round(rate * METER_SECONDS));
    s.rate = rate; s.captureRate = captureRate;
    s.phase = 'running';
    s.lastAck = s.lastAudio = performance.now();
    s.watchdog = setInterval(() => {
      if (S !== s) return;
      const now = performance.now();
      if (s.seq > s.acked && now - s.lastAck > ACK_TIMEOUT_MS) end(s, 'native-unresponsive');
      else if (now - s.lastAudio > ACK_TIMEOUT_MS) end(s, 'no-audio');
    }, ACK_CHECK_MS);
    post({ t: 'started', sid: s.sid, rate, captureRate, synthetic: s.synthetic }).catch(() => {});
  }
  async function start(options) {
    const o = options || {};
    if (S) end(S, 'restarted');
    const s = {
      sid: Number(o.sid) || 0, synthetic: !!o.synthetic, phase: 'starting', endedIn: '', reason: '',
      seq: 0, acked: 0, frames: 0, callbacks: 0, sumSq: 0, count: 0, stopping: false,
      rate: 0, captureRate: 0, lastAck: performance.now(),
    };
    S = s; last = s;
    try {
      if (s.synthetic) {
        if (typeof ffSyntheticSource !== 'function') throw named('SyntheticSourceUnavailable');
        s.source = ffSyntheticSource((x) => onAudio(s, x));
        begin(s, s.source.rate, 0);
        s.source.start();
        return;
      }
      const media = navigator.mediaDevices;
      if (!media || typeof media.getUserMedia !== 'function') throw named('MediaDevicesUnavailable');
      if (typeof AudioContext !== 'function') throw named('AudioContextUnavailable');
      // getUserMedia rejects with InvalidStateError under any other web audio session type.
      if (navigator.audioSession) { try { navigator.audioSession.type = 'play-and-record'; s.audioSession = true; } catch (_) {} }
      s.phase = 'media';
      const stream = await media.getUserMedia({ audio: { echoCancellation: o.echoCancellation !== false }, video: false });
      if (S !== s) { stream.getTracks().forEach((track) => track.stop()); return; }
      s.stream = stream;
      const track = stream.getAudioTracks()[0];
      if (!track) throw named('NoAudioTrack');
      track.onended = () => end(s, 'track-ended');
      const settings = typeof track.getSettings === 'function' ? track.getSettings() : {};
      const captureRate = Number(settings.sampleRate) || 0;
      s.phase = 'context';
      // Created only now, at the device rate: an idle context would hold the audio route.
      s.ctx = new AudioContext({ latencyHint: 'interactive' });
      await s.ctx.resume();
      if (S !== s) return;
      s.src = s.ctx.createMediaStreamSource(stream);
      s.sp = s.ctx.createScriptProcessor(SP_FRAMES, 1, 1);
      const mute = s.ctx.createGain();
      mute.gain.value = 0; // keeps the graph pulled and plays nothing
      s.src.connect(s.sp); s.sp.connect(mute); mute.connect(s.ctx.destination);
      begin(s, s.ctx.sampleRate, captureRate);
      s.sp.onaudioprocess = (event) => onAudio(s, event.inputBuffer.getChannelData(0));
      s.ctx.onstatechange = () => { if (s.ctx.state !== 'running') end(s, 'context-' + s.ctx.state); };
    } catch (error) {
      fail(s, errorName(error));
    }
  }
  function stop(sid) {
    const s = S;
    if (!s || !matches(s, sid) || s.stopping) return;
    if (s.phase !== 'running') { end(s, 'stopped-before-audio'); return; }
    s.stopping = true; s.phase = 'stopping';
    if (s.source) { s.source.stop(); finish(s, new Float32Array(0), []); return; }
    // The next callback flushes and ends; this covers a callback that never comes.
    s.stopTimer = setTimeout(() => { if (S === s) finish(s, new Float32Array(0), []); }, STOP_GRACE_MS);
  }
  function cancel(sid) {
    const s = S;
    if (s && matches(s, sid)) end(s, 'cancelled');
  }
  // Diagnostics for tests and debugging: states and counts only, never audio.
  function status() {
    const s = last;
    if (!s) return { phase: 'idle' };
    return {
      sid: s.sid, phase: s.phase, endedIn: s.endedIn, reason: s.reason, synthetic: s.synthetic,
      frames: s.frames, seq: s.seq, acked: s.acked, callbacks: s.callbacks,
      rate: s.rate, captureRate: s.captureRate,
      ctxState: s.ctx ? s.ctx.state : '', ctxTime: s.ctx ? s.ctx.currentTime : 0,
    };
  }
  window.ffCapture = { version: 1, start, stop, cancel, status };
  addEventListener('pagehide', () => { if (S) end(S, 'pagehide'); });
  document.addEventListener('visibilitychange', () => { if (document.hidden && S) end(S, 'hidden'); });
  // Report ready after the first rendering update. That update opens the page's connection to
  // WebKit's GPU process, which can stall the page for seconds while a cold GPU process starts;
  // that wait belongs to loading, not to the first dictation. A page that never renders is
  // ready after a second anyway.
  let announced = false;
  const announce = () => {
    if (announced) return;
    announced = true;
    post({ t: 'ready', v: 1, synthetic: typeof ffSyntheticSource === 'function' }).catch(() => {});
  };
  if (typeof requestAnimationFrame === 'function') {
    requestAnimationFrame(() => setTimeout(announce, 0));
    setTimeout(announce, 1000);
  } else {
    announce();
  }
})();
"""#
}
