import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ARC_CHAIN_ID,
  ARC_EXPLORER_URL,
  FACTORY_ADDRESS,
  LIVE_PROOF,
  PQ_VERIFIER,
  V1_CONTRACT,
  V1_SOURCE_HASH,
  connectWallet,
  createVaultCalldata,
  depositCalldata,
  executePaymentCalldata,
  explorerAddress,
  explorerTx,
  formatUsdc,
  parseUsdc,
  paymentDigest,
  readArcStatus,
  readFactoryVault,
  readVaultState,
  sendWalletTransaction,
  shorten,
  waitForReceipt,
  type Eip1193Provider,
  type VaultState,
} from "./lib/arcV2";
import {
  BrowserPQKeyManager,
  downloadPqBackup,
  hasPasskeyPrf,
  parsePqBackup,
  type PqBackup,
} from "./lib/pq";
import "./App.css";

type View = "home" | "setup" | "vault" | "send" | "security";

function App() {
  const keyManager = useMemo(() => new BrowserPQKeyManager(), []);
  const [view, setView] = useState<View>("home");
  const [wallet, setWallet] = useState<{
    provider: Eip1193Provider;
    address: string;
  } | null>(null);
  const [vault, setVault] = useState<VaultState | null>(null);
  const [pqPublicKey, setPqPublicKey] = useState<string | null>(null);
  const [backupReady, setBackupReady] = useState(false);
  const [arcReady, setArcReady] = useState(false);
  const passkeyPrf = useMemo(() => hasPasskeyPrf(), []);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [recipient, setRecipient] = useState("");
  const [amount, setAmount] = useState("");
  const [txHash, setTxHash] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const refresh = useCallback(async () => {
    try {
      const status = await readArcStatus();
      setArcReady(status.chainId === ARC_CHAIN_ID && status.verifierPresent);
      if (wallet && FACTORY_ADDRESS) {
        const vaultAddress = await readFactoryVault(wallet.address);
        setVault(vaultAddress ? await readVaultState(vaultAddress) : null);
      }
    } catch (refreshError) {
      setError(
        refreshError instanceof Error
          ? refreshError.message
          : "Arc read failed",
      );
    }
  }, [wallet]);

  useEffect(() => {
    const initialRefresh = window.setTimeout(() => {
      void refresh();
    }, 0);
    return () => {
      window.clearTimeout(initialRefresh);
      keyManager.close();
    };
  }, [keyManager, refresh]);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await action();
    } catch (actionError) {
      setError(
        actionError instanceof Error ? actionError.message : "Action failed",
      );
    } finally {
      setBusy(false);
    }
  };

  const onConnect = () =>
    void run(async () => {
      const connected = await connectWallet();
      setWallet(connected);
      setNotice(`Wallet connected: ${shorten(connected.address)}`);
      setView("setup");
    });
  const onGenerateKey = () =>
    void run(async () => {
      const generated = await keyManager.generate();
      setPqPublicKey(generated.publicKey);
      setBackupReady(false);
      setNotice(
        "Fresh PQ key generated in a dedicated worker. Download an encrypted backup before creating a vault.",
      );
    });
  const onBackup = () =>
    void run(async () => {
      const passphrase = window.prompt(
        "Create a recovery secret (16+ characters). It is used only in memory to encrypt the backup.",
      );
      if (!passphrase) throw new Error("Backup cancelled");
      const confirmation = window.prompt(
        "Enter the recovery secret again to confirm.",
      );
      if (passphrase !== confirmation)
        throw new Error("Recovery secrets did not match");
      downloadPqBackup(await keyManager.backup(passphrase));
      setBackupReady(true);
      setNotice(
        "Encrypted PQ backup downloaded. Store it separately from this browser.",
      );
    });
  const onRestore = () => fileInput.current?.click();
  const onBackupSelected = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    void run(async () => {
      const passphrase = window.prompt(
        "Enter the recovery secret for this encrypted PQ backup.",
      );
      if (!passphrase) throw new Error("Restore cancelled");
      const backup = parsePqBackup(await file.text()) as PqBackup;
      const restored = await keyManager.restore(backup, passphrase);
      setPqPublicKey(restored.publicKey);
      setBackupReady(true);
      setNotice(
        "PQ key restored into the signing worker. The recovery secret was not saved.",
      );
    });
  };
  const onCreateVault = () =>
    void run(async () => {
      if (!wallet) throw new Error("Connect the wallet first");
      if (!pqPublicKey) throw new Error("Create or restore a PQ key first");
      if (!backupReady)
        throw new Error("Create and download an encrypted PQ backup first");
      if (!FACTORY_ADDRESS)
        throw new Error(
          "V2 factory address is not configured yet; no V2 mainnet deployment has been broadcast",
        );
      const hash = await sendWalletTransaction(
        wallet.provider,
        wallet.address,
        FACTORY_ADDRESS,
        createVaultCalldata(pqPublicKey),
      );
      setTxHash(hash);
      const receipt = await waitForReceipt(wallet.provider, hash);
      if (receipt.status !== "0x1") throw new Error("Vault creation reverted");
      await refresh();
      setNotice(
        "Vault created. Keep the encrypted PQ backup safe before depositing.",
      );
      setView("vault");
    });
  const onDeposit = () =>
    void run(async () => {
      if (!wallet || !vault)
        throw new Error("Connect a wallet and create a vault first");
      const value = parseUsdc(amount);
      if (value <= 0n)
        throw new Error("Deposit amount must be greater than zero");
      const hash = await sendWalletTransaction(
        wallet.provider,
        wallet.address,
        vault.address,
        depositCalldata(),
        value,
      );
      setTxHash(hash);
      const receipt = await waitForReceipt(wallet.provider, hash);
      if (receipt.status !== "0x1") throw new Error("Deposit reverted");
      setAmount("");
      await refresh();
      setNotice("Deposit confirmed on Arc.");
    });
  const onSend = () =>
    void run(async () => {
      if (!wallet || !vault)
        throw new Error("Connect a wallet and create a vault first");
      if (!pqPublicKey)
        throw new Error("Load the active PQ key into the signing worker first");
      if (pqPublicKey.toLowerCase() !== vault.pqPublicKey.toLowerCase())
        throw new Error("Loaded PQ key does not match the vault key");
      const value = parseUsdc(amount);
      if (value <= 0n)
        throw new Error("Payment amount must be greater than zero");
      const normalizedRecipient = recipient.trim();
      if (!/^0x[\da-fA-F]{40}$/.test(normalizedRecipient))
        throw new Error("Enter a valid recipient address");
      if (value > vault.balance)
        throw new Error("Payment exceeds the current vault balance");
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 15 * 60);
      const digest = paymentDigest(
        vault.address,
        normalizedRecipient,
        value,
        vault.nonce,
        deadline,
      );
      setNotice("Signing the exact payment digest in the isolated PQ worker…");
      const signed = await keyManager.sign(digest);
      const hash = await sendWalletTransaction(
        wallet.provider,
        wallet.address,
        vault.address,
        executePaymentCalldata(
          normalizedRecipient,
          value,
          deadline,
          signed.signature,
        ),
      );
      setTxHash(hash);
      const receipt = await waitForReceipt(wallet.provider, hash);
      if (receipt.status !== "0x1") throw new Error("Payment reverted");
      setRecipient("");
      setAmount("");
      await refresh();
      setNotice(
        "Hybrid payment confirmed: wallet transaction + PQ signature accepted.",
      );
    });

  return (
    <main className="app-shell">
      <header className="topbar">
        <button
          className="brand"
          onClick={() => setView("home")}
          aria-label="Interlock home"
        >
          <span className="brand-mark">
            <i />
            <i />
          </span>
          <span>INTERLOCK</span>
        </button>
        <nav className="nav-links" aria-label="Main navigation">
          <button
            className={view === "vault" ? "active" : ""}
            onClick={() => setView("vault")}
          >
            Vault
          </button>
          <button
            className={view === "send" ? "active" : ""}
            onClick={() => setView("send")}
          >
            Send
          </button>
          <button
            className={view === "security" ? "active" : ""}
            onClick={() => setView("security")}
          >
            Security
          </button>
        </nav>
        <div className="top-actions">
          <span className={`network-chip ${arcReady ? "ready" : ""}`}>
            <span /> Arc mainnet · {ARC_CHAIN_ID}
          </span>
          <button className="wallet-button" onClick={onConnect} disabled={busy}>
            {wallet ? shorten(wallet.address) : "Connect wallet"}
          </button>
        </div>
      </header>
      <div className="page-shell">
        <div className="status-line" aria-live="polite">
          <span className={arcReady ? "status-ok" : "status-warn"}>
            <span />
            {arcReady ? "Arc verified" : "Checking Arc…"}
          </span>
          {FACTORY_ADDRESS ? (
            <span>V2 factory configured</span>
          ) : (
            <span>V2 factory not deployed</span>
          )}
          {txHash && (
            <a href={explorerTx(txHash)} target="_blank" rel="noreferrer">
              Latest transaction ↗
            </a>
          )}
        </div>
        {error && (
          <div className="alert error" role="alert">
            {error}
          </div>
        )}
        {notice && (
          <div className="alert notice" role="status">
            {notice}
          </div>
        )}
        {view === "home" && (
          <Home
            onStart={() => setView("setup")}
            onProof={() =>
              document
                .getElementById("live-proof")
                ?.scrollIntoView({ behavior: "smooth" })
            }
          />
        )}
        {view === "setup" && (
          <Setup
            wallet={wallet?.address}
            publicKey={pqPublicKey}
            backupReady={backupReady}
            passkeyPrf={passkeyPrf}
            busy={busy}
            onGenerate={onGenerateKey}
            onBackup={onBackup}
            onRestore={onRestore}
            onCreateVault={onCreateVault}
            onConnect={onConnect}
            fileInput={fileInput}
            onBackupSelected={onBackupSelected}
            factoryConfigured={Boolean(FACTORY_ADDRESS)}
          />
        )}
        {view === "vault" && (
          <VaultView
            wallet={wallet?.address}
            vault={vault}
            publicKey={pqPublicKey}
            amount={amount}
            setAmount={setAmount}
            busy={busy}
            onDeposit={onDeposit}
            onSetup={() => setView("setup")}
          />
        )}
        {view === "send" && (
          <SendView
            vault={vault}
            publicKey={pqPublicKey}
            recipient={recipient}
            amount={amount}
            setRecipient={setRecipient}
            setAmount={setAmount}
            busy={busy}
            onSend={onSend}
            onSetup={() => setView("setup")}
          />
        )}
        {view === "security" && <SecurityView passkeyPrf={passkeyPrf} />}
        {view === "home" && <LiveProof />}
        <footer className="footer">
          <span>
            Interlock V2 · hybrid post-quantum authorization for native USDC on
            Arc
          </span>
          <span>
            <a
              href="https://github.com/Iniwuura/interlock/tree/v2-development"
              target="_blank"
              rel="noreferrer"
            >
              Source ↗
            </a>
            <a href={ARC_EXPLORER_URL} target="_blank" rel="noreferrer">
              Arc explorer ↗
            </a>
          </span>
        </footer>
      </div>
    </main>
  );
}

function Home({
  onStart,
  onProof,
}: {
  onStart: () => void;
  onProof: () => void;
}) {
  return (
    <>
      <section className="hero-grid">
        <div className="hero-copy">
          <p className="eyebrow">A NEW CONTROL SURFACE FOR ARC</p>
          <h1>
            Keep one key in your wallet.
            <br />
            <em>One outside it.</em>
          </h1>
          <p className="hero-lede">
            Interlock is a hybrid vault for native USDC on Arc. Every payment
            needs the wallet owner and a local SLH-DSA-SHA2-128s signature.
          </p>
          <div className="hero-actions">
            <button className="button primary" onClick={onStart}>
              Create a vault
            </button>
            <button className="button quiet" onClick={onProof}>
              See the live proof ↓
            </button>
          </div>
          <p className="hero-caption">
            <span className="tiny-check">✓</span> No admin key. No owner-only
            escape hatch.
          </p>
        </div>
        <div
          className="hero-diagram"
          aria-label="Wallet approval and PQ approval converge at an Interlock vault"
        >
          <div className="diagram-kicker">TWO CREDENTIALS · ONE PAYMENT</div>
          <div className="diagram-canvas">
            <div className="beam beam-one" />
            <div className="beam beam-two" />
            <div className="diagram-card wallet-card">
              <span className="diagram-symbol">⌁</span>
              <span>Wallet</span>
              <small>normal EVM approval</small>
            </div>
            <div className="diagram-card pq-card">
              <span className="diagram-symbol">✣</span>
              <span>Security key</span>
              <small>local PQ signature</small>
            </div>
            <div className="diagram-vault">
              <span>IL</span>
              <strong>Interlock</strong>
              <small>exact intent checked</small>
            </div>
            <div className="beam beam-out" />
            <div className="diagram-recipient">
              <span>→</span>
              <span>Recipient</span>
              <small>native USDC</small>
            </div>
          </div>
        </div>
      </section>
      <section className="section-intro">
        <div>
          <p className="eyebrow">THE IDEA</p>
          <h2>Value only moves when both sides agree.</h2>
        </div>
        <p>
          Arc makes native USDC the asset and the gas token. Interlock uses that
          primitive to keep a second authorization path close to the user, while
          enforcement stays onchain.
        </p>
      </section>
      <section className="feature-rail">
        <Feature
          number="01"
          title="Bind the intent"
          text="Chain, vault, recipient, amount, nonce, and expiry are inside one digest."
        />
        <Feature
          number="02"
          title="Sign locally"
          text="SLH-DSA runs in a dedicated browser worker. Raw key material never goes to a backend."
        />
        <Feature
          number="03"
          title="Recover deliberately"
          text="A delayed PQ-key recovery can be canceled by the old key before it activates."
        />
      </section>
      <section className="callout">
        <span className="callout-index">V2</span>
        <div>
          <p className="eyebrow">BUILT FOR ARC</p>
          <h2>Not a quantum-proof claim.</h2>
          <p>
            It is a practical hybrid authorization boundary: familiar wallet
            custody plus a real post-quantum signature verified by Arc.
          </p>
        </div>
        <a href={explorerAddress(V1_CONTRACT)} target="_blank" rel="noreferrer">
          See the live V1 proof ↗
        </a>
      </section>
    </>
  );
}

function Setup({
  wallet,
  publicKey,
  backupReady,
  passkeyPrf,
  busy,
  onGenerate,
  onBackup,
  onRestore,
  onCreateVault,
  onConnect,
  fileInput,
  onBackupSelected,
  factoryConfigured,
}: {
  wallet?: string;
  publicKey: string | null;
  backupReady: boolean;
  passkeyPrf: boolean;
  busy: boolean;
  onGenerate: () => void;
  onBackup: () => void;
  onRestore: () => void;
  onCreateVault: () => void;
  onConnect: () => void;
  fileInput: React.RefObject<HTMLInputElement | null>;
  onBackupSelected: (event: React.ChangeEvent<HTMLInputElement>) => void;
  factoryConfigured: boolean;
}) {
  return (
    <section className="work-surface">
      <div className="surface-heading">
        <div>
          <p className="eyebrow">ONBOARDING</p>
          <h1>Set up your two approvals.</h1>
          <p>
            Do this in order. A vault should never receive funds before the
            encrypted PQ backup is safely stored.
          </p>
        </div>
        <span className="step-count">01 — 03</span>
      </div>
      <div className="setup-grid">
        <article className="setup-card">
          <span className="card-number">01</span>
          <h2>Connect your wallet</h2>
          <p>The connected wallet becomes the permanent owner of your vault.</p>
          {wallet ? (
            <div className="identity-pill">
              <span className="status-dot" />
              {shorten(wallet)}
              <small>owner account</small>
            </div>
          ) : (
            <button
              className="button primary full"
              onClick={onConnect}
              disabled={busy}
            >
              Connect wallet
            </button>
          )}
        </article>
        <article className={`setup-card ${publicKey ? "complete" : ""}`}>
          <span className="card-number">02</span>
          <h2>Create a PQ key</h2>
          <p>
            A fresh 48-byte seed is generated with browser CSPRNG, then held
            only inside a dedicated worker.
          </p>
          {publicKey ? (
            <>
              <div className="key-fingerprint">
                <span className="status-dot" />
                {shorten(publicKey, 12, 10)}
                <small>SLH-DSA-SHA2-128s · 32-byte public key</small>
                <small className="setup-requirement">
                  {backupReady
                    ? "Encrypted backup confirmed."
                    : "Backup required before vault creation."}
                </small>
              </div>
              <div className="inline-actions">
                <button
                  className="button quiet"
                  onClick={onBackup}
                  disabled={busy}
                >
                  Download encrypted backup
                </button>
                <button
                  className="text-button"
                  onClick={onRestore}
                  disabled={busy}
                >
                  Restore another
                </button>
              </div>
            </>
          ) : (
            <button
              className="button primary full"
              onClick={onGenerate}
              disabled={busy}
            >
              {busy ? "Generating…" : "Generate security key"}
            </button>
          )}
        </article>
        <article
          className={`setup-card ${factoryConfigured && publicKey && wallet && backupReady ? "complete" : ""}`}
        >
          <span className="card-number">03</span>
          <h2>Create your vault</h2>
          <p>
            The factory creates one non-upgradeable vault for this wallet. No
            company or admin can move funds.
          </p>
          {factoryConfigured ? (
            <button
              className="button primary full"
              onClick={onCreateVault}
              disabled={busy || !publicKey || !wallet || !backupReady}
            >
              {busy ? "Waiting for wallet…" : "Create vault"}
            </button>
          ) : (
            <div className="locked-note">
              <span>◌</span>
              <div>
                <strong>V2 deployment pending</strong>
                <small>
                  The product flow is ready. Configure the factory address after
                  the controlled V2 deployment rehearsal.
                </small>
              </div>
            </div>
          )}
        </article>
      </div>
      <div className="setup-foot">
        <div>
          <strong>Passkey PRF</strong>
          <span className={passkeyPrf ? "supported" : ""}>
            {passkeyPrf
              ? "Detected in this browser"
              : "Not detected; encrypted file backup is the path"}
          </span>
        </div>
        <div>
          <strong>Never save raw seed</strong>
          <span>
            Backups are AES-GCM encrypted and never written to localStorage.
          </span>
        </div>
      </div>
      <input
        ref={fileInput}
        className="visually-hidden"
        type="file"
        accept="application/json,.json"
        onChange={onBackupSelected}
      />
    </section>
  );
}

function VaultView({
  wallet,
  vault,
  publicKey,
  amount,
  setAmount,
  busy,
  onDeposit,
  onSetup,
}: {
  wallet?: string;
  vault: VaultState | null;
  publicKey: string | null;
  amount: string;
  setAmount: (value: string) => void;
  busy: boolean;
  onDeposit: () => void;
  onSetup: () => void;
}) {
  if (!wallet || !vault)
    return (
      <EmptyState
        title="Your vault is not connected"
        text="Connect a wallet and complete setup to see live vault state here."
        action="Open setup"
        onAction={onSetup}
      />
    );
  return (
    <section className="work-surface">
      <div className="surface-heading">
        <div>
          <p className="eyebrow">VAULT HOME</p>
          <h1>Good to see you, {shorten(wallet)}.</h1>
          <p>
            Live state is read from Arc mainnet. The vault has no upgrade path
            or admin custody.
          </p>
        </div>
        <a
          className="text-link"
          href={explorerAddress(vault.address)}
          target="_blank"
          rel="noreferrer"
        >
          Open vault ↗
        </a>
      </div>
      <div className="balance-panel">
        <div>
          <span className="eyebrow">AVAILABLE BALANCE</span>
          <strong>{formatUsdc(vault.balance)}</strong>
          <small>native USDC · 18 decimals on Arc</small>
        </div>
        <div className="balance-action">
          <label htmlFor="deposit-amount">Deposit amount</label>
          <div className="input-row">
            <input
              id="deposit-amount"
              inputMode="decimal"
              value={amount}
              onChange={(event) => setAmount(event.target.value)}
              placeholder="0.00"
            />
            <span>USDC</span>
          </div>
          <button
            className="button primary"
            onClick={onDeposit}
            disabled={busy}
          >
            Deposit from wallet
          </button>
        </div>
      </div>
      <div className="vault-grid">
        <DataPoint
          label="Owner"
          value={shorten(vault.owner)}
          detail="wallet authority"
        />
        <DataPoint
          label="Active PQ key"
          value={shorten(vault.pqPublicKey, 12, 10)}
          detail={
            publicKey?.toLowerCase() === vault.pqPublicKey.toLowerCase()
              ? "loaded in worker"
              : "load matching key to sign"
          }
        />
        <DataPoint
          label="Nonce"
          value={vault.nonce.toString()}
          detail="replay protection"
        />
        <DataPoint
          label="Recovery"
          value={
            vault.pendingPQKey === `0x${"0".repeat(64)}`
              ? "none pending"
              : "delayed request"
          }
          detail={
            vault.recoveryReadyAt === 0n
              ? "normal operation"
              : `ready at ${vault.recoveryReadyAt.toString()}`
          }
        />
      </div>
      <div className="surface-note">
        <span>◎</span>
        <p>
          Every payment requires the wallet owner and the active PQ key. Losing
          either credential can permanently lock funds.
        </p>
      </div>
    </section>
  );
}

function SendView({
  vault,
  publicKey,
  recipient,
  amount,
  setRecipient,
  setAmount,
  busy,
  onSend,
  onSetup,
}: {
  vault: VaultState | null;
  publicKey: string | null;
  recipient: string;
  amount: string;
  setRecipient: (value: string) => void;
  setAmount: (value: string) => void;
  busy: boolean;
  onSend: () => void;
  onSetup: () => void;
}) {
  if (!vault)
    return (
      <EmptyState
        title="Create a vault before sending"
        text="The send flow only appears when the app can read a real V2 vault from Arc."
        action="Open setup"
        onAction={onSetup}
      />
    );
  return (
    <section className="work-surface send-surface">
      <div className="surface-heading">
        <div>
          <p className="eyebrow">TWO-STEP PAYMENT</p>
          <h1>Review the exact intent.</h1>
          <p>
            The PQ worker signs first. Your wallet then approves the onchain
            transaction.
          </p>
        </div>
        <span className="intent-chip">
          <span /> ready to review
        </span>
      </div>
      <div className="send-layout">
        <div className="send-form">
          <label htmlFor="recipient">Recipient address</label>
          <input
            id="recipient"
            value={recipient}
            onChange={(event) => setRecipient(event.target.value)}
            placeholder="0x…"
            spellCheck="false"
            autoComplete="off"
          />
          <label htmlFor="send-amount">Amount</label>
          <div className="input-row wide">
            <input
              id="send-amount"
              inputMode="decimal"
              value={amount}
              onChange={(event) => setAmount(event.target.value)}
              placeholder="0.00"
            />
            <span>USDC</span>
          </div>
          <button
            className="button primary full"
            onClick={onSend}
            disabled={busy || !publicKey}
          >
            {busy ? "Signing / waiting…" : "Approve hybrid payment"}
          </button>
          <small className="form-foot">
            Deadline: 15 minutes · nonce: {vault.nonce.toString()} · no backend
            relay
          </small>
        </div>
        <div className="review-card">
          <span className="eyebrow">WHAT IS SIGNED</span>
          <div className="review-row">
            <span>Recipient</span>
            <strong>{recipient ? shorten(recipient, 10, 8) : "—"}</strong>
          </div>
          <div className="review-row">
            <span>Amount</span>
            <strong>{amount ? `${amount} USDC` : "—"}</strong>
          </div>
          <div className="review-row">
            <span>Vault nonce</span>
            <strong>{vault.nonce.toString()}</strong>
          </div>
          <div className="review-row">
            <span>PQ approval</span>
            <strong
              className={
                publicKey?.toLowerCase() === vault.pqPublicKey.toLowerCase()
                  ? "ok"
                  : "warn"
              }
            >
              {publicKey?.toLowerCase() === vault.pqPublicKey.toLowerCase()
                ? "loaded"
                : "not loaded"}
            </strong>
          </div>
          <p>
            Chain 5042 and the vault address are included in the digest.
            Changing any field invalidates the signature.
          </p>
        </div>
      </div>
    </section>
  );
}

function SecurityView({ passkeyPrf }: { passkeyPrf: boolean }) {
  return (
    <section className="work-surface">
      <div className="surface-heading">
        <div>
          <p className="eyebrow">SECURITY</p>
          <h1>Small system. Clear boundaries.</h1>
          <p>
            Interlock is experimental infrastructure, not an audited production
            wallet. The code makes the tradeoffs visible.
          </p>
        </div>
      </div>
      <div className="security-list">
        <SecurityRow
          index="01"
          title="Wallet theft alone"
          text="An attacker can request a delayed PQ recovery but cannot activate it without the new PQ proof; normal payments still need the existing key."
        />
        <SecurityRow
          index="02"
          title="PQ key theft alone"
          text="A stolen PQ credential cannot spend because every state-changing payment still requires the owner wallet transaction."
        />
        <SecurityRow
          index="03"
          title="Both credentials compromised"
          text="Both approvals are the policy. If both are compromised, funds can be stolen. There is no hidden company key."
        />
        <SecurityRow
          index="04"
          title="Credential loss"
          text="Losing either credential can permanently lock funds. Keep the encrypted backup and wallet recovery path separate."
        />
        <SecurityRow
          index="05"
          title="Passkey PRF"
          text={
            passkeyPrf
              ? "This browser exposes a PRF capability; Interlock does not silently use it without a verified enrollment flow."
              : "This browser does not expose a PRF capability. The product uses an encrypted file backup instead of pretending passkeys protect the PQ seed."
          }
        />
      </div>
      <div className="technical-record">
        <span className="eyebrow">V1 LIVE REFERENCE</span>
        <div>
          <strong>{V1_CONTRACT}</strong>
          <a
            href={explorerAddress(PQ_VERIFIER)}
            target="_blank"
            rel="noreferrer"
          >
            Arc PQ verifier ↗
          </a>
        </div>
        <small>
          Source hash {V1_SOURCE_HASH} · V2 remains un-deployed until the
          contract and custody path are independently reviewed.
        </small>
      </div>
    </section>
  );
}

function LiveProof() {
  return (
    <section className="live-proof" id="live-proof">
      <div className="section-heading">
        <div>
          <p className="eyebrow">LIVE ARC PROOF · V1</p>
          <h2>Five checks, recorded on mainnet.</h2>
        </div>
        <a
          className="text-link"
          href={explorerAddress(V1_CONTRACT)}
          target="_blank"
          rel="noreferrer"
        >
          Open contract ↗
        </a>
      </div>
      <div className="proof-list">
        {LIVE_PROOF.map((item, index) => (
          <a
            className="proof-row"
            href={explorerTx(item.hash)}
            target="_blank"
            rel="noreferrer"
            key={item.hash}
          >
            <span className="proof-number">0{index + 1}</span>
            <span className="proof-check">✓</span>
            <span>
              <strong>{item.label}</strong>
              <small>{item.detail}</small>
            </span>
            <code>{shorten(item.hash, 10, 8)}</code>
            <span>↗</span>
          </a>
        ))}
      </div>
      <p className="proof-note">
        This is a real Arc mainnet proof of the V1 security boundary. V2 is a
        separate factory/vault design and is intentionally not deployed from
        this build.
      </p>
    </section>
  );
}

function Feature({
  number,
  title,
  text,
}: {
  number: string;
  title: string;
  text: string;
}) {
  return (
    <article>
      <span>{number}</span>
      <h3>{title}</h3>
      <p>{text}</p>
    </article>
  );
}
function DataPoint({
  label,
  value,
  detail,
}: {
  label: string;
  value: string;
  detail: string;
}) {
  return (
    <div className="data-point">
      <span>{label}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </div>
  );
}
function SecurityRow({
  index,
  title,
  text,
}: {
  index: string;
  title: string;
  text: string;
}) {
  return (
    <div className="security-row">
      <span>{index}</span>
      <div>
        <h2>{title}</h2>
        <p>{text}</p>
      </div>
    </div>
  );
}
function EmptyState({
  title,
  text,
  action,
  onAction,
}: {
  title: string;
  text: string;
  action: string;
  onAction: () => void;
}) {
  return (
    <section className="empty-state">
      <span className="empty-mark">◎</span>
      <h1>{title}</h1>
      <p>{text}</p>
      <button className="button primary" onClick={onAction}>
        {action}
      </button>
    </section>
  );
}

export default App;
