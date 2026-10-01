import { slh_dsa_sha2_128s } from '../web/node_modules/@noble/post-quantum/slh-dsa.js';
import { keccak_256 } from '../web/node_modules/@noble/hashes/sha3.js';
import { utf8ToBytes } from '../web/node_modules/@noble/hashes/utils.js';

const RPC = process.env.ARC_RPC_URL ?? 'https://rpc.mainnet.arc.io';
const VERIFIER = '0x1800000000000000000000000000000000000004';
const message = Uint8Array.from({ length: 32 }, () => 0x11);
const tampered = Uint8Array.from(message);
tampered[0] ^= 0xff;

function word(value) {
  const output = new Uint8Array(32);
  let number = BigInt(value);
  for (let index = 31; index >= 0; index -= 1) {
    output[index] = Number(number & 0xffn);
    number >>= 8n;
  }
  return output;
}

function dynamic(value) {
  const padding = new Uint8Array((32 - (value.length % 32)) % 32);
  const output = new Uint8Array(32 + value.length + padding.length);
  output.set(word(value.length));
  output.set(value, 32);
  output.set(padding, 32 + value.length);
  return output;
}

function concat(...parts) {
  const output = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function hex(value) {
  return `0x${Array.from(value, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}

function calldata(publicKey, msg, signature) {
  const selector = keccak_256(utf8ToBytes('verifySlhDsaSha2128s(bytes,bytes,bytes)')).slice(0, 4);
  const keyPart = dynamic(publicKey);
  const messagePart = dynamic(msg);
  const signaturePart = dynamic(signature);
  const head = concat(word(96), word(96 + keyPart.length), word(96 + keyPart.length + messagePart.length));
  return hex(concat(selector, head, keyPart, messagePart, signaturePart));
}

async function rpc(method, params) {
  const response = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const body = await response.json();
  if (body.error) throw new Error(body.error.message ?? 'Arc RPC error');
  return body.result;
}

const seed = new Uint8Array(48).fill(9);
const keys = slh_dsa_sha2_128s.keygen(seed);
const signature = slh_dsa_sha2_128s.sign(message, keys.secretKey);
const valid = await rpc('eth_call', [{ to: VERIFIER, data: calldata(keys.publicKey, message, signature) }, 'latest']);
const invalid = await rpc('eth_call', [{ to: VERIFIER, data: calldata(keys.publicKey, tampered, signature) }, 'latest']);
if (valid.toLowerCase() !== `0x${'0'.repeat(63)}1` || invalid.toLowerCase() !== `0x${'0'.repeat(64)}`) {
  throw new Error(`unexpected verifier results: ${valid} / ${invalid}`);
}
console.log(`Noble SLH-DSA-SHA2-128s Arc check passed: publicKey=${keys.publicKey.length} signature=${signature.length}`);
