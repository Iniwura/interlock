# Interlock V2

## Hybrid post-quantum authorization for native USDC on Arc

Interlock is a small, user-owned vault system for Arc. A payment needs two independent approvals:

1. the vault owner’s normal EVM wallet transaction; and
2. a local SLH-DSA-SHA2-128s signature from the registered PQ key.

The result is a hybrid authorization boundary enforced by Solidity. Interlock does not call itself quantum-proof. It is experimental infrastructure, not an audited production wallet.

## Why Arc

Arc is a stablecoin-native EVM chain: USDC is the gas token, and native USDC uses 18 decimals. Interlock can therefore keep the payment asset in `msg.value` and `address(this).balance` while using Arc’s protocol-level SLH-DSA verifier at:

`0x1800000000000000000000000000000000000004`

The product targets Arc mainnet, chain ID `5042`, through `https://rpc.mainnet.arc.io`. Arc’s current EVM-specific behavior is documented in the [EVM differences reference](https://docs.arc.io/arc/references/evm-differences.md); the [Arc documentation index](https://docs.arc.io/llms.txt) is the source of truth for network and fee behavior.

## V1 live proof

V1 remains deployed and untouched at [`0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4`](https://explorer.arc.io/address/0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4). Its source hash is:

`def1d9be7177806abcabe65ab1277bca85e46eb52404873dbf1dad0ff3ee9d12`

The V1 deployment is preserved locally as the `interlock-v1-live-proof` tag. V2 is developed on a separate branch/worktree and has not been deployed.

| Check | Result |
| --- | --- |
| Funding | [`0x94854a…d06e3b4f`](https://explorer.arc.io/tx/0x94854a957f3bb907a1752038cea014f9f8a5e907c7fc4d2ee94f0c3dd06e3b4f) |
| Valid hybrid payment | [`0xcf4731…3df64ade`](https://explorer.arc.io/tx/0xcf473116755a991d8fd9c31f6d6dc7045e77df7ab22fd951ee3b3a373df64ade) |
| Tampered amount blocked | [`0x14922e…ae566783`](https://explorer.arc.io/tx/0x14922ec5d1a763bb777c7c3720516acb00c406f046bb26acb39dcbcbae566783) |
| Tampered recipient blocked | [`0xdcacb5…d81857dc`](https://explorer.arc.io/tx/0xdcacb522a45e37694710d470fa51d2db2676fddf8c8c58d490bba2bad81857dc) |
| Replay blocked by nonce | [`0xfc4ccf…9c835490`](https://explorer.arc.io/tx/0xfc4ccf9b6300012f7d3aa1fed01541cef6ba4859a56d4746f505fad99c835490) |
| Expired authorization blocked | [`0x9d6324…d1971d31`](https://explorer.arc.io/tx/0x9d632490d56da934680b67adc5ecce20e2d5dce57757d0d407b94ca2d1971d31) |

## V2 architecture

`InterlockFactory` creates one non-upgradeable `InterlockVaultV2` per owner address. The factory records `vaultOf(owner)` and emits `VaultCreated`; it has no admin, upgrade, pause, rescue, or company-wallet path. One vault per wallet keeps discovery unambiguous. A user who wants separate vaults can use separate owner accounts.

`InterlockVaultV2` stores the immutable owner, the active PQ public key, a payment nonce, and delayed-recovery state. It uses Arc native USDC transfers and the deployed Arc verifier directly. A malformed verifier response, wrong signature length, verifier failure, zero recipient, zero amount, expired authorization, insufficient balance, failed transfer, or reentrant callback reverts the whole call.

## Payment authorization

The browser computes and signs:

```text
keccak256(abi.encode(
  "INTERLOCK_PAYMENT_V2",
  block.chainid,
  address(this),
  recipient,
  amount,
  nonce,
  deadline
))
```

The active PQ signature is checked by Arc. The owner wallet then sends `executePayment`. Because the chain ID, vault address, recipient, amount, nonce, and deadline are all bound, a signature cannot be moved to another chain, vault, recipient, amount, or nonce. The nonce advances only after the transfer succeeds.

Normal key rotation uses another domain-separated digest and requires both the old key’s approval and a valid signature from the new key. Rotation advances the payment nonce and cannot race with delayed recovery.

## Delayed recovery

If the owner still controls the wallet but has lost the old PQ key, the owner can request a new PQ key. The request waits 72 hours. During that window the old PQ key can cancel it using an owner transaction plus an old-key signature. After the delay, activation still requires the owner wallet and a proof from the new key. Recovery changes only the PQ credential; it never moves funds, and activation advances the payment nonce.

This design is intentionally conservative:

- stolen wallet alone cannot make a payment or activate recovery without the PQ side;
- stolen PQ key alone cannot make a payment without the owner wallet;
- losing either credential can permanently lock funds;
- compromising both credentials permits authorized payments;
- a pending recovery is public and has an explicit cancel window; and
- there is no owner-only payment bypass or administrator recovery key.

## Browser custody

The V2 frontend uses `@noble/post-quantum` for the exact `SLH-DSA-SHA2-128s` parameter set. Key generation and signing happen in a dedicated Web Worker with browser CSPRNG. The raw seed is not put in localStorage, URLs, analytics, or a backend. The user can download an AES-GCM/PBKDF2 encrypted backup file and restore it with a manually entered recovery secret; the secret is not stored by the app.

Passkey PRF is feature-detected. The UI does not claim that a passkey protects the PQ seed unless the browser exposes the capability and a verified enrollment flow has been completed. The encrypted backup remains the explicit recovery path.

## Reproduce

From the V2 worktree:

```sh
forge fmt --check
forge build
forge test -vv
forge lint
bash -n script/*.sh

cd web
npm ci
npm run lint
npm run build
```

The read-only Rust/PQ proof requires the separately checked-out probe:

```sh
ARC_PQ_PROBE_DIR=/path/to/arc-pq-probe \
  ARC_RPC_URL=https://rpc.mainnet.arc.io \
  ./script/real_arc_pq_check.sh

ARC_PQ_PROBE_DIR=/path/to/arc-pq-probe \
  ARC_RPC_URL=https://rpc.mainnet.arc.io \
  ./script/real_arc_v2_pq_check.sh
```

The V2 checker creates only deterministic test fixtures in a temporary directory. It performs read-only calls to the real Arc verifier and does not deploy, fund, sign with production material, or broadcast. `script/real_arc_noble_pq_check.mjs` performs the same compatibility check using the browser JavaScript implementation.

The frontend is intentionally safe to build before V2 deployment. Until `VITE_INTERLOCK_FACTORY_ADDRESS` is configured, it shows the deployment gate and cannot pretend that a V2 vault exists. After a controlled deployment, set that public address at build time:

```sh
VITE_INTERLOCK_FACTORY_ADDRESS=0x... npm run build
```

## Current limitations

- V2 factory and vault have not been deployed to Arc mainnet.
- The browser signing path is new and requires independent review before holding value.
- The 2-of-2 model has permanent-lock risk when either credential is lost.
- Both credentials compromised means funds can be stolen.
- The delayed recovery flow has local tests and verifier compatibility checks, but no live onchain rehearsal yet.
- V1’s live proof does not prove V2 deployment safety.
- This is experimental infrastructure, not an audited production wallet.

## License

MIT. See [LICENSE](LICENSE).
