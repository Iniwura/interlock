export const ARC_RPC_URL = import.meta.env.VITE_ARC_RPC_URL ?? 'https://rpc.mainnet.arc.io';
export const ARC_CHAIN_ID = 5042;
export const CONTRACT_ADDRESS = '0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4';
export const PQ_VERIFIER = '0x1800000000000000000000000000000000000004';
export const EXPLORER_URL = 'https://explorer.arc.io';

const SELECTORS = {
  owner: '0x8da5cb5b',
  pqPublicKey: '0x98c577f9',
  nonce: '0xaffed0e0',
  balance: '0xb69ef8a8',
  verifier: '0xfcf404bd',
} as const;

type RpcResponse<T> = { result?: T; error?: { message?: string } };

async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch(ARC_RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }),
  });

  if (!response.ok) {
    throw new Error(`Arc RPC returned HTTP ${response.status}`);
  }

  const payload = (await response.json()) as RpcResponse<T>;
  if (payload.error) {
    throw new Error(payload.error.message ?? 'Arc RPC request failed');
  }
  if (payload.result === undefined) {
    throw new Error('Arc RPC returned no result');
  }
  return payload.result;
}

async function call(selector: string): Promise<string> {
  return rpc<string>('eth_call', [{ to: CONTRACT_ADDRESS, data: selector }, 'latest']);
}

function wordToAddress(word: string): string {
  return `0x${word.slice(-40)}`;
}

function wordToBytes32(word: string): string {
  return `0x${word.replace(/^0x/, '').padStart(64, '0').slice(-64)}`;
}

function hexToBigInt(word: string): bigint {
  return BigInt(word);
}

export function shorten(value: string, leading = 8, trailing = 6): string {
  if (value.length <= leading + trailing + 3) return value;
  return `${value.slice(0, leading)}…${value.slice(-trailing)}`;
}

export function formatUsdc(value: bigint): string {
  return `${(Number(value) / 1e18).toFixed(6)} USDC`;
}

export type VaultState = {
  chainId: number;
  bytecodePresent: boolean;
  owner: string;
  pqPublicKey: string;
  nonce: bigint;
  balance: bigint;
  verifier: string;
  updatedAt: string;
};

export async function readVaultState(): Promise<VaultState> {
  const [chainHex, bytecode, ownerWord, pqWord, nonceWord, balanceWord, verifierWord] = await Promise.all([
    rpc<string>('eth_chainId', []),
    rpc<string>('eth_getCode', [CONTRACT_ADDRESS, 'latest']),
    call(SELECTORS.owner),
    call(SELECTORS.pqPublicKey),
    call(SELECTORS.nonce),
    call(SELECTORS.balance),
    call(SELECTORS.verifier),
  ]);

  return {
    chainId: Number.parseInt(chainHex, 16),
    bytecodePresent: bytecode !== '0x',
    owner: wordToAddress(ownerWord),
    pqPublicKey: wordToBytes32(pqWord),
    nonce: hexToBigInt(nonceWord),
    balance: hexToBigInt(balanceWord),
    verifier: wordToAddress(verifierWord),
    updatedAt: new Date().toISOString(),
  };
}

export function explorerAddress(address: string): string {
  return `${EXPLORER_URL}/address/${address}`;
}

export function explorerTx(hash: string): string {
  return `${EXPLORER_URL}/tx/${hash}`;
}

export const LIVE_PROOF = [
  {
    label: 'Valid hybrid payment',
    detail: 'Wallet + PQ authorization accepted',
    hash: '0xcf473116755a991d8fd9c31f6d6dc7045e77df7ab22fd951ee3b3a373df64ade',
  },
  {
    label: 'Tampered amount blocked',
    detail: 'Digest mismatch reverted',
    hash: '0x14922ec5d1a763bb777c7c3720516acb00c406f046bb26acb39dcbcbae566783',
  },
  {
    label: 'Tampered recipient blocked',
    detail: 'Recipient binding reverted',
    hash: '0xdcacb522a45e37694710d470fa51d2db2676fddf8c8c58d490bba2bad81857dc',
  },
  {
    label: 'Replay blocked',
    detail: 'Nonce advanced after first use',
    hash: '0xfc4ccf9b6300012f7d3aa1fed01541cef6ba4859a56d4746f505fad99c835490',
  },
  {
    label: 'Expired authorization blocked',
    detail: 'Vault expiry check reverted',
    hash: '0x9d632490d56da934680b67adc5ecce20e2d5dce57757d0d407b94ca2d1971d31',
  },
] as const;

export const DEPLOYMENT_TX = '0xa8c53d89a84a4f3c5fbd35a517dee3b900b8d32b17778d360c4076804295fa07';
