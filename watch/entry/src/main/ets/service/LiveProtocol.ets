export interface LiveFrame { session: number; sequence: number; capturedAt: number; pcm: ArrayBuffer; }
export function decodeLiveFrame(bytes: Uint8Array): LiveFrame | undefined {
  if (bytes.byteLength < 26 || bytes.byteLength > 3224) return undefined;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== 0x41325657) return undefined;
  const size = view.getUint32(20, true);
  if (size === 0 || size % 2 !== 0 || size !== bytes.byteLength - 24) return undefined;
  const capturedAt = view.getFloat64(12, true);
  if (!Number.isFinite(capturedAt)) return undefined;
  return { session: view.getUint32(4, true), sequence: view.getUint32(8, true), capturedAt: capturedAt,
    pcm: bytes.buffer.slice(bytes.byteOffset + 24, bytes.byteOffset + bytes.byteLength) };
}
