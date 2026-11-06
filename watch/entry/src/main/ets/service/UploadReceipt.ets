export interface UploadReceipt {
  filename: string;
  bytes: number;
  sha256: string;
  cloud_synced: boolean;
  cloud_verified: boolean;
  cloud_path: string;
}

/** An HTTP success, server-local copy or old cloud_synced alone cannot authorize deletion. */
export function canDeleteRecording(receipt: UploadReceipt, filename: string, bytes: number, sha256: string): boolean {
  return receipt.cloud_synced === true && receipt.cloud_verified === true &&
    receipt.filename === filename && receipt.bytes === bytes &&
    /^[a-f0-9]{64}$/.test(receipt.sha256) && receipt.sha256 === sha256 &&
    typeof receipt.cloud_path === 'string' && receipt.cloud_path.startsWith('disk:/');
}
