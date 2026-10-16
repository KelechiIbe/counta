// Voice notes go to Gemini as 16 kHz mono WAV. Browsers record in different containers (Chrome: WebM/Opus,
// iPhone Safari: MP4/AAC), and WAV is a format every model endpoint reads. Falls back to the original
// recording if the browser cannot decode it.
export async function toWav(blob: Blob, rate = 16000): Promise<Blob> {
  try {
    const AC: typeof AudioContext = (window as any).AudioContext || (window as any).webkitAudioContext;
    const OAC: typeof OfflineAudioContext = (window as any).OfflineAudioContext || (window as any).webkitOfflineAudioContext;
    if (!AC || !OAC) return blob;
    const ctx = new AC();
    const decoded: AudioBuffer = await new Promise((res, rej) => {
      blob.arrayBuffer().then((buf) => {
        const p = ctx.decodeAudioData(buf, res, rej);
        if (p && typeof (p as Promise<AudioBuffer>).then === 'function') (p as Promise<AudioBuffer>).then(res, rej);
      }, rej);
    });
    ctx.close?.().catch(() => {});
    const frames = Math.max(1, Math.ceil(decoded.duration * rate));
    const off = new OAC(1, frames, rate);
    const src = off.createBufferSource();
    src.buffer = decoded;
    src.connect(off.destination);
    src.start(0);
    const out = await off.startRendering();
    return new Blob([encodeWav(out.getChannelData(0), rate)], { type: 'audio/wav' });
  } catch {
    return blob;
  }
}

function encodeWav(samples: Float32Array, rate: number): ArrayBuffer {
  const buf = new ArrayBuffer(44 + samples.length * 2);
  const v = new DataView(buf);
  const str = (o: number, s: string) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  str(0, 'RIFF'); v.setUint32(4, 36 + samples.length * 2, true); str(8, 'WAVE');
  str(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, 'data'); v.setUint32(40, samples.length * 2, true);
  let o = 44;
  for (let i = 0; i < samples.length; i++, o += 2) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    v.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return buf;
}
