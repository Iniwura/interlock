# Security policy

Interlock is experimental infrastructure, not an audited production wallet. V1 is live on Arc, but V2 is a separate, not-yet-deployed design.

## Security model

A V2 payment requires both the owner wallet transaction and a valid SLH-DSA-SHA2-128s signature checked by Arc’s PQ verifier. The payment digest binds chain ID, vault address, recipient, amount, nonce, and deadline. There is no owner-only payment bypass, administrator key, upgrade path, pause escape hatch, or backend signer.

The delayed PQ recovery path changes only the registered PQ key. It waits 72 hours, can be canceled by the old PQ key plus the owner wallet during the delay, and requires the owner wallet plus new-key proof to activate. Activation advances the payment nonce.

## Credential risks

- Losing either the owner wallet or the PQ credential can permanently lock funds.
- If both credentials are compromised, an attacker can authorize payments.
- The encrypted PQ backup is a recovery aid, not a guarantee; protect its recovery secret separately.
- Browser extensions, the operating system, wallet software, and the user’s backup process remain in scope for compromise.

## Reporting

Do not include private keys, PQ seeds, passphrases, wallet keystores, keyring values, encrypted credential files, or local credential paths in an issue or pull request. For a suspected vulnerability, open a private report with the maintainers before public disclosure. Include a minimal reproduction that contains no secrets and identify whether the issue affects the live V1 contract or the un-deployed V2 branch.
