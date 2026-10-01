# Interlock

## Hybrid post-quantum authorization for USDC on Arc

Interlock is a small experimental vault that requires two independent approvals before native USDC moves:

1. the owner’s normal EVM wallet, and
2. a real SLH-DSA-SHA2-128s signature checked by Arc’s PQ verifier precompile.

The result is a hybrid authorization boundary: familiar wallet ownership plus a post-quantum signing path, with the final policy enforced by Solidity on Arc mainnet.

## Why Arc

Arc exposes an onchain SLH-DSA verifier at `0x1800000000000000000000000000000000000004`. Interlock calls that verifier directly, so the PQ authorization is validated by the chain rather than by a browser, API, or trusted relayer. Arc’s native asset is USDC with 18 decimals; Interlock therefore uses `msg.value` and `address(this).balance`, not an ERC-20 allowance flow.

## Live system

| Field | Value |
| --- | --- |
| Network | Arc mainnet · chain ID `5042` |
| Contract | [`0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4`](https://explorer.arc.io/address/0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4) |
| Deployment | [`0xa8c53d89a84a4f3c5fbd35a517dee3b900b8d32b17778d360c4076804295fa07`](https://explorer.arc.io/tx/0xa8c53d89a84a4f3c5fbd35a517dee3b900b8d32b17778d360c4076804295fa07) |
| Owner | `0x7d567Fa1d5fe35737BbF045f47667e13298Ee176` |
| Active PQ public key | `0x9537fe572feba88ee169008bfc6c8b7dd420f92884ca7a377449bfb76d401e18` |
| Source SHA-256 | `def1d9be7177806abcabe65ab1277bca85e46eb52404873dbf1dad0ff3ee9d12` |

The published site is intentionally read-only. It reads the live contract over Arc JSON-RPC and never handles a private key, PQ seed, passphrase, or browser signing flow.

## Authorization model

Every payment signs a digest containing:

```text
keccak256(abi.encode(
  "INTERLOCK_PAYMENT_V1",
  block.chainid,
  address(this),
  recipient,
  amount,
  nonce,
  deadline
))
```

The vault checks owner authorization, deadline, exact PQ signature length, verifier success, current nonce, and native balance before transferring. The nonce advances only after a successful payment, so a valid authorization cannot be replayed or moved to another chain, vault, recipient, amount, or time window.

PQ rotation uses a separate domain-separated digest. The owner must approve the rotation, the current PQ key must authorize it, and the new PQ key must prove possession. The rotation increments the same nonce. The live rotation path is implemented and locally tested, but has not yet been executed onchain; the live key above remains active.

## Live Arc proof

The proof used tiny values and the production PQ key. The funding transaction succeeded, the valid payment returned `1e-6` native USDC to the owner, and every negative case reverted onchain.

| Check | Result | Transaction |
| --- | --- | --- |
| Fund vault with `2e-6` native USDC | ✓ | [`0x94854a…d06e3b4f`](https://explorer.arc.io/tx/0x94854a957f3bb907a1752038cea014f9f8a5e907c7fc4d2ee94f0c3dd06e3b4f) |
| Valid hybrid payment | ✓ | [`0xcf4731…3df64ade`](https://explorer.arc.io/tx/0xcf473116755a991d8fd9c31f6d6dc7045e77df7ab22fd951ee3b3a373df64ade) |
| Tampered amount blocked | ✓ | [`0x14922e…ae566783`](https://explorer.arc.io/tx/0x14922ec5d1a763bb777c7c3720516acb00c406f046bb26acb39dcbcbae566783) |
| Tampered recipient blocked | ✓ | [`0xdcacb5…d81857dc`](https://explorer.arc.io/tx/0xdcacb522a45e37694710d470fa51d2db2676fddf8c8c58d490bba2bad81857dc) |
| Replay blocked by nonce | ✓ | [`0xfc4ccf…9c835490`](https://explorer.arc.io/tx/0xfc4ccf9b6300012f7d3aa1fed01541cef6ba4859a56d4746f505fad99c835490) |
| Expired authorization blocked | ✓ | [`0x9d6324…d1971d31`](https://explorer.arc.io/tx/0x9d632490d56da934680b67adc5ecce20e2d5dce57757d0d407b94ca2d1971d31) |

The final live state was nonce `1` with `0.000001000000000000` native USDC remaining in the vault. The independent real-Arc checker also validated accepted and rejected SLH-DSA fixtures, digest parity with Solidity, and rotation proofs against the live Arc precompile.

## Threat model and limitations

- Interlock protects the payment authorization boundary, not the safety of every surrounding wallet or operating system.
- The model is 2-of-2: losing either the owner credential or PQ credential can permanently lock funds. There is no owner-only bypass.
- If both credentials are compromised, an attacker can authorize payments.
- PQ rotation is designed to require old-key approval plus new-key proof, but live rotation has not yet been exercised.
- This repository is experimental infrastructure, not an audited production wallet. Use only deliberately tiny values while evaluating it.
- The site does not sign transactions and does not prove custody of the PQ private seed.

Do not oversell this as “quantum-proof.” The precise claim is hybrid post-quantum authorization for USDC on Arc.

## Reproduce locally

From the repository root:

```sh
forge fmt --check
forge build
forge test -vv
forge lint
bash -n script/*.sh
```

The deterministic local Rust fixture generator lives in the companion `arc-pq-probe` project. Set its path explicitly when running the real-Arc check; no credential path is assumed by the public scripts:

```sh
ARC_PQ_PROBE_DIR=/path/to/arc-pq-probe \
  ARC_RPC_URL=https://rpc.mainnet.arc.io \
  ./script/real_arc_pq_check.sh
```

The check is read-only and calls the real Arc verifier. It does not deploy, fund, sign, or broadcast.

The read-only frontend is in [`web/`](web/):

```sh
cd web
npm ci
npm run lint
npm run build
npm run dev
```

Production PQ generation and signing must happen outside this repository. Keep encrypted seed material, keyring entries, keystores, passphrases, and any raw private key out of Git, `.env` files, browser bundles, and logs.

## License

MIT. See [LICENSE](LICENSE).
