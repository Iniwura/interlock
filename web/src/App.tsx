import { useCallback, useEffect, useState } from 'react';
import {
  ARC_CHAIN_ID,
  ARC_RPC_URL,
  CONTRACT_ADDRESS,
  DEPLOYMENT_TX,
  EXPLORER_URL,
  LIVE_PROOF,
  PQ_VERIFIER,
  explorerAddress,
  explorerTx,
  formatUsdc,
  readVaultState,
  shorten,
  type VaultState,
} from './lib/arc';
import './App.css';

const SOURCE_HASH = 'def1d9be7177806abcabe65ab1277bca85e46eb52404873dbf1dad0ff3ee9d12';

function App() {
  const [state, setState] = useState<VaultState | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setState(await readVaultState());
    } catch (readError) {
      setError(readError instanceof Error ? readError.message : 'Unable to read Arc state');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const initialRead = window.setTimeout(() => void refresh(), 0);
    const interval = window.setInterval(() => void refresh(), 30_000);
    return () => {
      window.clearTimeout(initialRead);
      window.clearInterval(interval);
    };
  }, [refresh]);

  const networkHealthy = state?.chainId === ARC_CHAIN_ID && state.bytecodePresent && state.verifier.toLowerCase() === PQ_VERIFIER.toLowerCase();

  return (
    <main>
      <nav className="nav shell">
        <a className="brand" href="#top" aria-label="Interlock home">
          <span className="brand-mark" aria-hidden="true"><i /><i /></span>
          <span>INTERLOCK</span>
        </a>
        <div className="nav-links">
          <a href="#proof">Live proof</a>
          <a href="#security">Security</a>
          <a href="https://github.com/Iniwuura/interlock" target="_blank" rel="noreferrer">Source <span aria-hidden="true">↗</span></a>
        </div>
        <span className={`network-pill ${networkHealthy ? '' : 'is-warn'}`}>
          <span className="pulse" /> Arc mainnet · {ARC_CHAIN_ID}
        </span>
      </nav>

      <section className="hero shell" id="top">
        <div className="hero-copy">
          <p className="eyebrow"><span className="eyebrow-line" /> ARC MICROGRANTS · LIVE SYSTEM</p>
          <h1>Two approvals.<br /><em>One safer</em> payment.</h1>
          <p className="hero-lede">Hybrid post-quantum authorization for USDC on Arc. Interlock pairs a normal wallet approval with a real SLH-DSA signature before value moves.</p>
          <div className="hero-actions">
            <a className="button button-primary" href="#proof">Explore the proof <span>↓</span></a>
            <a className="button button-quiet" href={explorerAddress(CONTRACT_ADDRESS)} target="_blank" rel="noreferrer">View live contract <span>↗</span></a>
          </div>
          <p className="hero-note"><span className="check-dot">✓</span> Verified on Arc mainnet · read-only observer</p>
        </div>
        <div className="hero-visual" aria-label="Wallet approval and PQ approval converge on an Interlock vault before payment">
          <div className="visual-grid" />
          <div className="flow-label flow-label-wallet">wallet approval</div>
          <div className="flow-label flow-label-pq">PQ approval</div>
          <div className="flow-node node-wallet"><span className="node-icon">⌁</span><strong>Wallet</strong><small>owner key</small></div>
          <div className="flow-node node-pq"><span className="node-icon node-icon-pq">✣</span><strong>SLH-DSA</strong><small>active PQ key</small></div>
          <div className="flow-rail rail-wallet" /><div className="flow-rail rail-pq" />
          <div className="flow-node node-vault"><span className="vault-ring"><span>IL</span></span><strong>InterlockVault</strong><small>both proofs required</small></div>
          <div className="flow-rail rail-out" /><div className="flow-label flow-label-out">authorized payment</div>
          <div className="flow-node node-payment"><span className="payment-arrow">→</span><strong>USDC</strong><small>recipient</small></div>
        </div>
      </section>

      <section className="proof-banner shell">
        <div><span className="section-kicker">THE CLAIM</span><h2>Cryptographic intent, enforced onchain.</h2></div>
        <p>The live vault accepted one real hybrid payment, then rejected changes to amount, recipient, nonce, and deadline. Every authorization is bound to Arc chain 5042 and this vault address.</p>
      </section>

      <section className="state-section shell" id="state">
        <div className="section-heading"><div><span className="section-kicker">LIVE VAULT STATE</span><h2>Observed on Arc, right now.</h2></div><button className="refresh" onClick={() => void refresh()} disabled={loading}>{loading ? 'Reading…' : 'Refresh state ↻'}</button></div>
        {error && <div className="read-error">Could not read live state: {error}. <button onClick={() => void refresh()}>Try again</button></div>}
        <div className="state-grid">
          <StateCard label="Owner / wallet" value={state ? shorten(state.owner) : '—'} detail="normal EVM authority" href={state ? explorerAddress(state.owner) : undefined} loading={loading} />
          <StateCard label="Active PQ key" value={state ? shorten(state.pqPublicKey, 10, 8) : '—'} detail="SLH-DSA-SHA2-128s · public" loading={loading} />
          <StateCard label="Vault nonce" value={state ? state.nonce.toString() : '—'} detail="replay protection counter" loading={loading} />
          <StateCard label="Vault balance" value={state ? formatUsdc(state.balance) : '—'} detail="native USDC · 18 decimals" loading={loading} />
        </div>
        <div className="state-meta"><span><span className={`status-dot ${networkHealthy ? '' : 'warn'}`} /> {networkHealthy ? 'Arc connection healthy' : 'Connection needs attention'}</span><span>Auto-refreshes every 30 seconds</span></div>
      </section>

      <section className="proof-section shell" id="proof">
        <div className="section-heading proof-heading"><div><span className="section-kicker">LIVE PROOF · ARC MAINNET</span><h2>Five checks. One contract.</h2></div><a className="text-link" href={explorerAddress(CONTRACT_ADDRESS)} target="_blank" rel="noreferrer">Open explorer <span>↗</span></a></div>
        <div className="proof-list">{LIVE_PROOF.map((item, index) => <a className="proof-row" href={explorerTx(item.hash)} target="_blank" rel="noreferrer" key={item.hash}><span className="proof-index">0{index + 1}</span><span className="proof-check">✓</span><span className="proof-name"><strong>{item.label}</strong><small>{item.detail}</small></span><span className="proof-hash">{shorten(item.hash, 10, 8)}</span><span className="proof-arrow">↗</span></a>)}</div>
        <p className="proof-footnote">The PQ rotation path is implemented and locally tested, but has not yet been exercised onchain. The active key above is unchanged.</p>
      </section>

      <section className="security-section shell" id="security">
        <div className="security-intro"><span className="section-kicker">SECURITY MODEL</span><h2>Designed for the handoff between today and the next cryptographic era.</h2><p>Interlock does not call itself quantum-proof. It adds a second, independent authorization layer to a normal wallet flow, using Arc’s native SLH-DSA verifier.</p></div>
        <div className="security-points"><SecurityPoint number="01" title="Hybrid approval" text="The owner EOA and the active PQ key must both authorize the exact payment digest." /><SecurityPoint number="02" title="Bound intent" text="Chain ID, vault address, recipient, amount, nonce, and deadline are all inside the signed digest." /><SecurityPoint number="03" title="No browser secrets" text="This site is intentionally read-only. PQ signing stays outside the browser in protected custody." /></div>
      </section>

      <section className="limitations shell">
        <div><span className="section-kicker">LIMITATIONS</span><h2>Small system. Honest boundaries.</h2></div>
        <div className="limitation-copy"><p><strong>Credential loss is final.</strong> Interlock is a 2-of-2 authorization model: losing either credential can permanently lock funds because there is no owner-only bypass.</p><p><strong>Compromise is still compromise.</strong> If both credentials are stolen, an attacker can authorize a payment. This is experimental infrastructure, not an audited production wallet.</p></div>
      </section>

      <section className="technical shell">
        <details><summary><span><span className="section-kicker">TECHNICAL DETAILS</span><strong>Open the verification record</strong></span><span className="details-plus">+</span></summary><div className="technical-grid"><TechItem label="Network" value={`Arc mainnet · chain ${ARC_CHAIN_ID}`} /><TechItem label="Contract" value={CONTRACT_ADDRESS} mono href={explorerAddress(CONTRACT_ADDRESS)} /><TechItem label="PQ verifier" value={PQ_VERIFIER} mono href={explorerAddress(PQ_VERIFIER)} /><TechItem label="RPC" value={ARC_RPC_URL} mono /><TechItem label="Deployment tx" value={shorten(DEPLOYMENT_TX, 14, 10)} mono href={explorerTx(DEPLOYMENT_TX)} /><TechItem label="Source SHA-256" value={SOURCE_HASH} mono /><TechItem label="Local suite" value="25 / 25 Foundry tests passed" /><TechItem label="Signing" value="SLH-DSA-SHA2-128s · 7,856-byte signatures" /></div></details>
      </section>

      <footer className="footer shell"><div className="footer-brand"><span className="brand-mark" aria-hidden="true"><i /><i /></span><span>INTERLOCK</span></div><p>Hybrid post-quantum authorization for USDC on Arc.</p><div className="footer-links"><a href={EXPLORER_URL} target="_blank" rel="noreferrer">Arc explorer ↗</a><a href="https://github.com/Iniwuura/interlock" target="_blank" rel="noreferrer">GitHub ↗</a></div></footer>
    </main>
  );
}

function StateCard({ label, value, detail, href, loading }: { label: string; value: string; detail: string; href?: string; loading: boolean }) {
  return <div className="state-card"><span className="card-label">{label}</span><strong className={loading ? 'skeleton' : ''}>{loading ? 'Loading…' : href ? <a href={href} target="_blank" rel="noreferrer">{value} ↗</a> : value}</strong><small>{detail}</small></div>;
}

function SecurityPoint({ number, title, text }: { number: string; title: string; text: string }) {
  return <div className="security-point"><span>{number}</span><div><h3>{title}</h3><p>{text}</p></div></div>;
}

function TechItem({ label, value, mono = false, href }: { label: string; value: string; mono?: boolean; href?: string }) {
  return <div className="tech-item"><span>{label}</span>{href ? <a className={mono ? 'mono' : ''} href={href} target="_blank" rel="noreferrer">{value} ↗</a> : <strong className={mono ? 'mono' : ''}>{value}</strong>}</div>;
}

export default App;
