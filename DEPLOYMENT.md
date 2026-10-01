# Arc deployment record

Interlock has completed a controlled Arc mainnet deployment and a tiny-value live proof. The production contract was not modified after deployment.

## Live deployment

| Field | Value |
| --- | --- |
| Network | Arc mainnet |
| Chain ID | `5042` |
| RPC | [`https://rpc.mainnet.arc.io`](https://rpc.mainnet.arc.io) |
| Contract | [`0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4`](https://explorer.arc.io/address/0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4) |
| Deployment transaction | [`0xa8c53d89a84a4f3c5fbd35a517dee3b900b8d32b17778d360c4076804295fa07`](https://explorer.arc.io/tx/0xa8c53d89a84a4f3c5fbd35a517dee3b900b8d32b17778d360c4076804295fa07) |
| Owner | `0x7d567Fa1d5fe35737BbF045f47667e13298Ee176` |
| Active PQ public key | `0x9537fe572feba88ee169008bfc6c8b7dd420f92884ca7a377449bfb76d401e18` |
| Public frontend | [`interlock-amber.vercel.app`](https://interlock-amber.vercel.app/) |
| Arc PQ verifier | `0x1800000000000000000000000000000000000004` |
| Source SHA-256 | `def1d9be7177806abcabe65ab1277bca85e46eb52404873dbf1dad0ff3ee9d12` |

## Live proof

The funding transaction deposited `0.000002000000000000` native USDC. The valid authorization paid `0.000001000000000000` native USDC back to the owner. Attack cases were broadcast as deliberately reverting transactions and did not alter state.

| Check | Transaction | Result |
| --- | --- | --- |
| Vault funding | [`0x94854a957f3bb907a1752038cea014f9f8a5e907c7fc4d2ee94f0c3dd06e3b4f`](https://explorer.arc.io/tx/0x94854a957f3bb907a1752038cea014f9f8a5e907c7fc4d2ee94f0c3dd06e3b4f) | Succeeded |
| Valid hybrid payment | [`0xcf473116755a991d8fd9c31f6d6dc7045e77df7ab22fd951ee3b3a373df64ade`](https://explorer.arc.io/tx/0xcf473116755a991d8fd9c31f6d6dc7045e77df7ab22fd951ee3b3a373df64ade) | Succeeded; nonce `0 → 1` |
| Tampered amount | [`0x14922ec5d1a763bb777c7c3720516acb00c406f046bb26acb39dcbcbae566783`](https://explorer.arc.io/tx/0x14922ec5d1a763bb777c7c3720516acb00c406f046bb26acb39dcbcbae566783) | Reverted as expected |
| Tampered recipient | [`0xdcacb522a45e37694710d470fa51d2db2676fddf8c8c58d490bba2bad81857dc`](https://explorer.arc.io/tx/0xdcacb522a45e37694710d470fa51d2db2676fddf8c8c58d490bba2bad81857dc) | Reverted as expected |
| Replay | [`0xfc4ccf9b6300012f7d3aa1fed01541cef6ba4859a56d4746f505fad99c835490`](https://explorer.arc.io/tx/0xfc4ccf9b6300012f7d3aa1fed01541cef6ba4859a56d4746f505fad99c835490) | Reverted as expected |
| Expired authorization | [`0x9d632490d56da934680b67adc5ecce20e2d5dce57757d0d407b94ca2d1971d31`](https://explorer.arc.io/tx/0x9d632490d56da934680b67adc5ecce20d2d5dce57757d0d407b94ca2d1971d31) | Reverted as expected |

PQ key rotation was intentionally deferred. The active key remains the deployment key above.

## Reproduce read-only verification

From the repository root, use the public deployment values:

```sh
export ARC_RPC_URL=https://rpc.mainnet.arc.io
export INTERLOCK_VAULT=0x3d00D0779A76b32B6916A895570B4DE5e4ECF5f4
export EXPECTED_OWNER=0x7d567Fa1d5fe35737BbF045f47667e13298Ee176
export EXPECTED_PQ_PUBLIC_KEY=0x9537fe572feba88ee169008bfc6c8b7dd420f92884ca7a377449bfb76d401e18
./script/verify_deployment.sh
```

The initial deployment readback expected nonce `0` and zero balance. After the live proof, read the current nonce and balance directly from the public RPC or the frontend. No private key, encrypted seed, passphrase, or local credential path is needed for read-only verification.

The Arc PQ integration checker requires a separately checked-out Rust probe. Set `ARC_PQ_PROBE_DIR` to that checkout and run:

```sh
ARC_PQ_PROBE_DIR=/path/to/arc-pq-probe ./script/real_arc_pq_check.sh
```

## Local validation

```sh
forge fmt --check
forge build
forge test -vv
forge lint
cargo fmt --check
cargo check
```

The repository does not contain production signing material. Deployment and payment signing must use an encrypted external signer and the separately managed PQ custody workflow. Do not place secrets in this repository or broadcast transactions from an unreviewed checkout.
