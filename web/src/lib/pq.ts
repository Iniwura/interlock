export type PqBackup = {
  format: 'interlock-pq-backup-v1';
  algorithm: 'SLH-DSA-SHA2-128s';
  publicKey: string;
  salt: string;
  iv: string;
  ciphertext: string;
  iterations: number;
};

type WorkerResponse = { id: number; ok: boolean; result?: unknown; error?: string };

type KeyResult = { publicKey: string; signatureLength?: number; signature?: string };

export class BrowserPQKeyManager {
  private readonly worker = new Worker(new URL('../workers/pq.worker.ts', import.meta.url), { type: 'module' });
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (reason: Error) => void }>();

  constructor() {
    this.worker.onmessage = (event: MessageEvent<WorkerResponse>) => {
      const request = this.pending.get(event.data.id);
      if (!request) return;
      this.pending.delete(event.data.id);
      if (event.data.ok) request.resolve(event.data.result);
      else request.reject(new Error(event.data.error ?? 'PQ worker failed'));
    };
  }

  private request<T>(message: Record<string, unknown>): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
      this.worker.postMessage({ ...message, id });
    });
  }

  async generate(): Promise<KeyResult> {
    return this.request<KeyResult>({ type: 'generate' });
  }

  async restore(backup: PqBackup, passphrase: string): Promise<KeyResult> {
    return this.request<KeyResult>({ type: 'restore', backup, passphrase });
  }

  async backup(passphrase: string): Promise<PqBackup> {
    return this.request<PqBackup>({ type: 'backup', passphrase });
  }

  async sign(digest: string): Promise<KeyResult & { signature: string }> {
    return this.request<KeyResult & { signature: string }>({ type: 'sign', digest });
  }

  forget(): void {
    void this.request({ type: 'forget' });
  }

  close(): void {
    this.worker.terminate();
    for (const request of this.pending.values()) request.reject(new Error('PQ worker closed'));
    this.pending.clear();
  }
}

export function downloadPqBackup(backup: PqBackup): void {
  const file = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(file);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = 'interlock-pq-backup.json';
  anchor.click();
  URL.revokeObjectURL(url);
}

export function parsePqBackup(value: string): PqBackup {
  const parsed = JSON.parse(value) as Partial<PqBackup>;
  if (
    parsed.format !== 'interlock-pq-backup-v1' ||
    parsed.algorithm !== 'SLH-DSA-SHA2-128s' ||
    typeof parsed.publicKey !== 'string' ||
    typeof parsed.salt !== 'string' ||
    typeof parsed.iv !== 'string' ||
    typeof parsed.ciphertext !== 'string' ||
    parsed.iterations !== 250_000
  ) throw new Error('Invalid Interlock PQ backup file');
  return parsed as PqBackup;
}

export function hasPasskeyPrf(): boolean {
  const credential = globalThis.PublicKeyCredential as typeof PublicKeyCredential & {
    getClientCapabilities?: () => Promise<Record<string, boolean>>;
  } | undefined;
  return Boolean(credential?.getClientCapabilities);
}
