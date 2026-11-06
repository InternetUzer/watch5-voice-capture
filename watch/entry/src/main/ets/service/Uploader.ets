import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
/** User-initiated upload of WAV clips to an authenticated HTTPS endpoint. */
export class Uploader {
  private readonly maxSingleFileBytes: number = 8 * 1024 * 1024;
  async uploadFiles(context: common.UIAbilityContext, files: string[], endpoint: string, key: string): Promise<number> {
    if (!endpoint.startsWith('https://')) throw new Error('HTTPS required');
    if (!key.trim()) throw new Error('Missing API key');
    let transferred = 0;
    for (const name of files) {
      if (!/^capture_[0-9]+\.wav$/.test(name)) continue;
      const path = `${context.filesDir}/${name}`;
      const stat = fs.statSync(path);
      if (stat.size > this.maxSingleFileBytes) throw new Error('File exceeds upload limit: ' + name);
      const opened = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const bytes = new ArrayBuffer(stat.size);
      try { fs.readSync(opened.fd, bytes); } finally { fs.closeSync(opened); }
      const req = http.createHttp();
      try {
        const result = await req.request(`${endpoint}?filename=${encodeURIComponent(name)}`, {
          method: http.RequestMethod.POST,
          header: { 'Content-Type': 'audio/wav', 'X-Device-Key': key },
          extraData: bytes, connectTimeout: 20000, readTimeout: 60000
        });
        if (result.responseCode !== 201) throw new Error(`HTTP ${result.responseCode}`);
      } finally { req.destroy(); }
      transferred++;
    }
    return transferred;
  }
}