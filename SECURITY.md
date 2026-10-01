# Security policy

Interlock is experimental infrastructure and has not received an independent security audit. Do not treat the live deployment as a production wallet or deposit more than a deliberately tiny amount while evaluating it.

## Scope

Security-sensitive areas include:

- owner-only authorization and reentrancy handling in `src/InterlockVault.sol`;
- chain, vault, recipient, amount, nonce, and deadline binding;
- Arc PQ verifier calls and malformed-return handling;
- PQ seed custody, key rotation, and signer isolation; and
- the read-only frontend’s guarantee that it never handles private material.

## Credential model

The vault intentionally has no owner-only recovery path. Loss of either the owner wallet or active PQ signing credential can permanently lock funds. Compromise of both credentials permits authorized payments. Keep the wallet keystore, PQ encrypted seed, keyring passphrase, and backups in separate protected locations.

Never submit private keys, PQ seeds, passphrases, keystore files, or keyring values in an issue or pull request. The public frontend must remain read-only unless a future signing design can preserve this boundary.

## Reporting

Please open a private report with the repository maintainers before publishing a reproducible exploit. Include the affected commit, reproduction steps that do not contain secrets, and whether the issue affects the deployed contract. For urgent issues, use GitHub’s private vulnerability reporting if enabled for the repository.
