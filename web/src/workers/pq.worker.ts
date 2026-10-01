/// <reference lib="webworker" />

import { slh_dsa_sha2_128s } from '@noble/post-quantum/slh-dsa.js';
import { randomBytes } from '@noble/post-quantum/utils.js';

type Request =
  | { id: number; type: 'generate' }
  | { id: number; type: 'sign'; digest: string }
  | { id: number; type: 'backup'; passphrase: string }
  | { id: number; type: 'restore'; backup: Backup; passphrase: string }
  | { id: number; type: 'forget' };

type Backup = {
  format: 'interlock-pq-backup-v1';
  algorithm: 'SLH-DSA-SHA2-128s';
  publicKey: string;
  salt: string;
  iv: string;
  ciphertext: string;
  iterations: number;
};

let secretKey: Uint8Array | null = null;
let seed: Uint8Array | null = null;
let publicKey: Uint8Array | null = null;

const encoder = new TextEncoder();
function owned(value: Uint8Array): ArrayBuffer {  const copy = new Uint8Array(value.byteLength);  copy.set(value);  return copy.buffer;}

function hex(bytes: Uint8Array): string {
  return `0x${Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('')}`;
}

function bytes(value: string): Uint8Array {
  const normalized = value.replace(/^0x/, '');
  if (normalized.length % 2 !== 0 || !/^[da-fA-F]*$/.test(normalized)) throw new Error('Invalid hexadecimal input');
  return Uint8Array.from(normalized.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
}

function base64(value: Uint8Array): string {
  let binary = '';
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function encryptionKey(passphrase: string, salt: Uint8Array): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey('raw', owned(encoder.encode(passphrase)), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt: owned(salt), iterations: 250_000, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

async function makeBackup(passphrase: string): Promise<Backup> {
  if (!seed || !publicKey) throw new Error('Create or restore a PQ key first');
  if (passphrase.length < 16) throw new Error('Use a recovery secret of at least 16 characters');
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const key = await encryptionKey(passphrase, salt);
  const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: owned(iv) }, key, owned(seed));
  return {
    format: 'interlock-pq-backup-v1',
    algorithm: 'SLH-DSA-SHA2-128s',
    publicKey: hex(publicKey),
    salt: base64(salt),
    iv: base64(iv),
    ciphertext: base64(new Uint8Array(encrypted)),
    iterations: 250_000,
  };
}

async function restoreBackup(backup: Backup, passphrase: string): Promise<string> {
  if (backup.format !== 'interlock-pq-backup-v1' || backup.algorithm !== 'SLH-DSA-SHA2-128s') {
    throw new Error('Unsupported Interlock PQ backup');
  }
  if (backup.iterations !== 250_000) throw new Error('Unsupported backup work factor');
  const salt = fromBase64(backup.salt);
  const iv = fromBase64(backup.iv);
  const key = await encryptionKey(passphrase, salt);
  const restored = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: owned(iv) }, key, owned(fromBase64(backup.ciphertext))));
  if (restored.length !== 48) throw new Error('PQ backup did not contain a 48-byte seed');
  const keys = slh_dsa_sha2_128s.keygen(restored);
  const derivedPublicKey = hex(keys.publicKey);
  if (derivedPublicKey.toLowerCase() !== backup.publicKey.toLowerCase()) throw new Error('PQ backup public key mismatch');
  seed?.fill(0);
  secretKey?.fill(0);
  publicKey?.fill(0);
  seed = restored;
  secretKey = new Uint8Array(keys.secretKey);
  publicKey = new Uint8Array(keys.publicKey);
  return derivedPublicKey;
}

async function handle(request: Request): Promise<unknown> {
  if (request.type === 'generate') {
    seed?.fill(0);
    secretKey?.fill(0);
    publicKey?.fill(0);
    seed = randomBytes(48);
    const keys = slh_dsa_sha2_128s.keygen(seed);
    secretKey = new Uint8Array(keys.secretKey);
    publicKey = new Uint8Array(keys.publicKey);
    return { publicKey: hex(publicKey), signatureLength: 7856 };
  }
  if (request.type === 'restore') return { publicKey: await restoreBackup(request.backup, request.passphrase) };
  if (request.type === 'backup') return makeBackup(request.passphrase);
  if (request.type === 'sign') {
    if (!secretKey || !publicKey) throw new Error('Load or create a PQ key first');
    const digest = bytes(request.digest);
    if (digest.length !== 32) throw new Error('Payment digest must be 32 bytes');
    const signature = slh_dsa_sha2_128s.sign(digest, secretKey);
    return { publicKey: hex(publicKey), signature: hex(signature) };
  }
  seed?.fill(0);
  secretKey?.fill(0);
  publicKey?.fill(0);
  seed = null;
  secretKey = null;
  publicKey = null;
  return { forgotten: true };
}

self.onmessage = (event: MessageEvent<Request>) => {
  void handle(event.data)
    .then((result) => self.postMessage({ id: event.data.id, ok: true, result }))
    .catch((error: unknown) => self.postMessage({ id: event.data.id, ok: false, error: error instanceof Error ? error.message : 'PQ worker failed' }));
};
