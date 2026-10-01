import { keccak_256 } from '@noble/hashes/sha3.js';
import { utf8ToBytes } from '@noble/hashes/utils.js';

export const ARC_RPC_URL = import.meta.env.VITE_ARC_RPC_URL ?? 'https://rpc.mainnet.arc.io';
export const ARC_CHAIN_ID = 5042;
export const ARC_CHAIN_HEX = '0x13b2';
export const ARC_EXPLORER_URL = 'https://explorer.arc.io';
export const PQ_VERIFIER = '0x1800000000000000000000000000000000000004';
export const FACTORY_ADDRESS = import.meta.env.VITE_INTERLOCK_FACTORY_ADDRESS ?? '';
export const V1_CONTRACT = '0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4';
export const V1_SOURCE_HASH = 'def1d9be7177806abcabe65ab1277bca85e46eb52404873dbf1dad0ff3ee9d12';

export const LIVE_PROOF = [
  { label: 'Valid hybrid payment', detail: 'Wallet + PQ authorization accepted', hash: '0xcf473116755a991d8fd9c31f6d6dc7045e77df7ab22fd951ee3b3a373df64ade' },
  { label: 'Tampered amount blocked', detail: 'Digest mismatch reverted', hash: '0x14922ec5d1a763bb777c7c3720516acb00c406f046bb26acb39dcbcbae566783' },
  { label: 'Tampered recipient blocked', detail: 'Recipient binding reverted', hash: '0xdcacb522a45e37694710d470fa51d2db2676fddf8c8c58d490bba2bad81857dc' },
  { label: 'Replay blocked', detail: 'Nonce advanced after first use', hash: '0xfc4ccf9b6300012f7d3aa1fed01541cef6ba4859a56d4746f505fad99c835490' },
  { label: 'Expired authorization blocked', detail: 'Vault expiry check reverted', hash: '0x9d632490d56da934680b67adc5ecce20e2d5dce57757d0d407b94ca2d1971d31' },
] as const;

export const DEPLOYMENT_TX = '0xa8c53d89a84a4f3c5fbd35a517dee3b900b8d32b17778d360c4076804295fa07';

type RpcResponse<T> = { result?: T; error?: { message?: string } };

export type Eip1193Provider = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
};

declare global {
  interface Window {
    ethereum?: Eip1193Provider;
  }
}

async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch(ARC_RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }),
  });
  if (!response.ok) throw new Error(`Arc RPC returned HTTP ${response.status}`);
  const payload = (await response.json()) as RpcResponse<T>;
  if (payload.error) throw new Error(payload.error.message ?? 'Arc RPC request failed');
  if (payload.result === undefined) throw new Error('Arc RPC returned no result');
  return payload.result;
}

function bytesToHex(value: Uint8Array): string {
  return `0x${Array.from(value, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}

function hexToBytes(value: string): Uint8Array {
  const normalized = value.replace(/^0x/, '');
  return Uint8Array.from(normalized.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
}

function word(value: bigint | number | string): Uint8Array {
  const output = new Uint8Array(32);
  let number = typeof value === 'string' ? BigInt(value) : BigInt(value);
  for (let index = 31; index >= 0; index -= 1) {
    output[index] = Number(number & 0xffn);
    number >>= 8n;
  }
  return output;
}

function addressWord(address: string): Uint8Array {
  const output = new Uint8Array(32);
  output.set(hexToBytes(address), 12);
  return output;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function selector(signature: string): string {
  return bytesToHex(keccak_256(utf8ToBytes(signature)).slice(0, 4));
}


function dynamicBytes(value: Uint8Array): Uint8Array {
  const padding = new Uint8Array((32 - (value.length % 32)) % 32);
  return concat(word(value.length), value, padding);
}

function encodedCall(signature: string, head: Uint8Array[], dynamicParts: Uint8Array[] = []): string {
  const headBytes = concat(...head);
  let offset = headBytes.length + dynamicParts.length * 32;
  const offsets = dynamicParts.map((part) => {
    const current = word(offset);
    offset += part.length;
    return current;
  });
  return bytesToHex(concat(hexToBytes(selector(signature)), headBytes, ...offsets, ...dynamicParts));
}

export function shorten(value: string, leading = 8, trailing = 6): string {
  if (value.length <= leading + trailing + 3) return value;
  return `${value.slice(0, leading)}…${value.slice(-trailing)}`;
}

export function formatUsdc(value: bigint): string {
  const whole = value / 1_000_000_000_000_000_000n;
  const fraction = (value % 1_000_000_000_000_000_000n).toString().padStart(18, '0').slice(0, 6);
  return `${whole.toString()}.${fraction} USDC`;
}

export function parseUsdc(value: string): bigint {
  const trimmed = value.trim();
  if (!/^\d+(\.\d{1,18})?$/.test(trimmed) || BigInt(trimmed.split('.')[0]) < 0n) throw new Error('Enter a valid positive USDC amount');
  const [whole, fraction = ''] = trimmed.split('.');
  return BigInt(whole) * 1_000_000_000_000_000_000n + BigInt(fraction.padEnd(18, '0') || '0');
}

export type VaultState = {
  address: string;
  bytecodePresent: boolean;
  owner: string;
  pqPublicKey: string;
  nonce: bigint;
  balance: bigint;
  pendingPQKey: string;
  recoveryReadyAt: bigint;
};

const readSelector = {
  owner: selector('owner()'),
  pqPublicKey: selector('pqPublicKey()'),
  nonce: selector('nonce()'),
  balance: selector('balance()'),
  pendingPQKey: selector('pendingPQKey()'),
  recoveryReadyAt: selector('recoveryReadyAt()'),
};

async function call(address: string, data: string): Promise<string> {
  return rpc<string>('eth_call', [{ to: address, data }, 'latest']);
}

function addressFromWord(value: string): string {
  return `0x${value.replace(/^0x/, '').slice(-40)}`;
}

function bytes32FromWord(value: string): string {
  return `0x${value.replace(/^0x/, '').padStart(64, '0').slice(-64)}`;
}

export async function readVaultState(address: string): Promise<VaultState> {
  const [code, owner, pq, nonce, balance, pending, readyAt] = await Promise.all([
    rpc<string>('eth_getCode', [address, 'latest']),
    call(address, readSelector.owner),
    call(address, readSelector.pqPublicKey),
    call(address, readSelector.nonce),
    call(address, readSelector.balance),
    call(address, readSelector.pendingPQKey),
    call(address, readSelector.recoveryReadyAt),
  ]);
  return {
    address,
    bytecodePresent: code !== '0x',
    owner: addressFromWord(owner),
    pqPublicKey: bytes32FromWord(pq),
    nonce: BigInt(nonce),
    balance: BigInt(balance),
    pendingPQKey: bytes32FromWord(pending),
    recoveryReadyAt: BigInt(readyAt),
  };
}

export async function readFactoryVault(owner: string): Promise<string | null> {
  if (!FACTORY_ADDRESS) return null;
  const data = selector('vaultOf(address)') + bytesToHex(addressWord(owner)).slice(2);
  const address = addressFromWord(await call(FACTORY_ADDRESS, data));
  return /^0x0{40}$/i.test(address) ? null : address;
}

export async function readArcChainId(): Promise<number> {
  return Number.parseInt(await rpc<string>('eth_chainId', []), 16);
}

export async function readArcStatus(): Promise<{ chainId: number; verifierPresent: boolean }> {
  const [chainId, code] = await Promise.all([
    readArcChainId(),
    rpc<string>('eth_getCode', [PQ_VERIFIER, 'latest']),
  ]);
  return { chainId, verifierPresent: code.toLowerCase() === '0xef' };
}

export async function connectWallet(): Promise<{ provider: Eip1193Provider; address: string }> {
  const provider = window.ethereum;
  if (!provider) throw new Error('Install or unlock an EVM wallet to continue');
  await provider.request({ method: 'eth_requestAccounts' });
  try {
    await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: ARC_CHAIN_HEX }] });
  } catch (error) {
    const code = (error as { code?: number }).code;
    if (code !== 4902) throw error;
    await provider.request({
      method: 'wallet_addEthereumChain',
      params: [{ chainId: ARC_CHAIN_HEX, chainName: 'Arc Mainnet', nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 }, rpcUrls: [ARC_RPC_URL], blockExplorerUrls: [ARC_EXPLORER_URL] }],
    });
  }
  const accounts = (await provider.request({ method: 'eth_accounts' })) as string[];
  const address = accounts[0];
  if (!address) throw new Error('The wallet did not return an account');
  return { provider, address };
}

export async function sendWalletTransaction(provider: Eip1193Provider, from: string, to: string, data: string, value = 0n): Promise<string> {
  return provider.request({ method: 'eth_sendTransaction', params: [{ from, to, data, value: `0x${value.toString(16)}` }] }) as Promise<string>;
}

export async function waitForReceipt(provider: Eip1193Provider, hash: string): Promise<{ status: string; gasUsed?: string }> {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const receipt = (await provider.request({ method: 'eth_getTransactionReceipt', params: [hash] })) as { status: string; gasUsed?: string } | null;
    if (receipt) return receipt;
    await new Promise((resolve) => window.setTimeout(resolve, 500));
  }
  throw new Error('The Arc receipt did not arrive within 20 seconds');
}

export function createVaultCalldata(publicKey: string): string {
  return `${selector('createVault(bytes32)')}${publicKey.replace(/^0x/, '').padStart(64, '0')}`;
}

export function depositCalldata(): string {
  return selector('deposit()');
}

export function executePaymentCalldata(recipient: string, amount: bigint, deadline: bigint, signature: string): string {
  return encodedCall(
    'executePayment(address,uint256,uint256,bytes)',
    [addressWord(recipient), word(amount), word(deadline)],
    [dynamicBytes(hexToBytes(signature))],
  );
}

export function paymentDigest(vault: string, recipient: string, amount: bigint, nonce: bigint, deadline: bigint): string {
  return bytesToHex(keccak_256(concat(
    keccak_256(utf8ToBytes('INTERLOCK_PAYMENT_V2')),
    word(ARC_CHAIN_ID),
    addressWord(vault),
    addressWord(recipient),
    word(amount),
    word(nonce),
    word(deadline),
  )));
}

export function explorerAddress(address: string): string {
  return `${ARC_EXPLORER_URL}/address/${address}`;
}

export function explorerTx(hash: string): string {
  return `${ARC_EXPLORER_URL}/tx/${hash}`;
}
