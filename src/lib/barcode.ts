// Barcode reading from the camera. Chrome on Android has a built-in BarcodeDetector; iPhone Safari
// and Firefox do not, so they load a WebAssembly reader (zxing) the first time the camera opens.
export type Detector = { detect: (src: HTMLVideoElement) => Promise<{ rawValue: string }[]> };

const WANT = ['ean_13', 'ean_8', 'upc_a', 'upc_e', 'qr_code', 'code_128', 'code_39'];

export async function makeDetector(): Promise<Detector | null> {
  const Native = (window as any).BarcodeDetector;
  if (Native) {
    try {
      const formats: string[] | null = await Native.getSupportedFormats?.().catch(() => null);
      const use = formats ? formats.filter((f) => WANT.includes(f)) : WANT;
      if (use.length) return new Native({ formats: use });
    } catch { /* fall through to the wasm reader */ }
  }
  try {
    const [{ BarcodeDetector, prepareZXingModule }, { default: wasmUrl }] = await Promise.all([
      import('barcode-detector/ponyfill'),
      import('zxing-wasm/reader/zxing_reader.wasm?url'),
    ]);
    prepareZXingModule({ overrides: { locateFile: (path: string, prefix: string) => (path.endsWith('.wasm') ? wasmUrl : prefix + path) } });
    return new BarcodeDetector({ formats: WANT as any }) as unknown as Detector;
  } catch {
    return null;
  }
}
