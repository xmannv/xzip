import { downloadUrl } from '../../content/site-content'
import { comparisonRows, featureCards, formatGroups } from './landing-data'
import {
  GitHubBadge,
  LandingFooter,
  LandingNav,
  useTheme,
} from './landing-chrome'
import {
  ArchivePreviewRows,
  ArchivePreviewTitle,
  LandingShowcase,
} from './landing-showcase'
function ArchiveWindow() {
  return (
    <div className="hero-archive">
      <div className="demo-toolbar">
        <span className="landing-lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </span>
        <ArchivePreviewTitle />
        <span>+ Add</span>
        <strong>Extract</strong>
      </div>
      <ArchivePreviewRows />
    </div>
  )
}
function SecurityCard() {
  return (
    <div className="security-card">
      <div>
        <span className="toggle" />
        <b>Encrypt with password</b>
        <small>AES-256</small>
      </div>
      <div>
        <code>••••••••••••</code>
        <button type="button">Suggest</button>
      </div>
      <p>
        <i>!</i>ZIP shows filenames even with a password. Choose 7Z to hide
        them.
      </p>
    </div>
  )
}

export function LandingPage() {
  const { preference, cycleTheme } = useTheme()
  return (
    <div className="landing-root" data-testid="landing-root">
      <LandingNav preference={preference} cycleTheme={cycleTheme} />
      <main>
        <header className="landing-hero">
          <h1>
            The archive utility
            <br />
            <span>macOS deserves.</span>
          </h1>
          <p>
            Compress, browse, and extract 30+ formats with a simple drag and
            drop. Powerful when you need it, invisible when you don’t.
          </p>
          <div className="hero-ctas">
            <a
              className="pill primary"
              href={downloadUrl}
              target="_blank"
              rel="noopener noreferrer"
            >
              Download for Mac — Free
            </a>
            <GitHubBadge />
          </div>
          <small>
            macOS 15+ · 12 MB · Apple Silicon &amp; Intel · Notarized
          </small>
          <div className="hero-preview">
            <i className="badge pdf">PDF</i>
            <i className="badge png">PNG</i>
            <i className="badge rar">RAR</i>
            <i className="badge seven">7Z</i>
            <ArchiveWindow />
          </div>
        </header>
        <LandingShowcase />
        <section className="landing-formats landing-container">
          <h2>Reads 30+ formats. Writes 12.</h2>
          <p>Blue means compress and extract. Gray means extract.</p>
          <div>
            {formatGroups.both.map((format) => (
              <span className="both" key={format}>
                {format}
              </span>
            ))}
            {formatGroups.extractOnly.map((format) => (
              <span key={format}>{format}</span>
            ))}
          </div>
        </section>
        <section id="features" className="landing-features landing-container">
          <h2>Power tools, zero clutter.</h2>
          <div>
            {featureCards.map((card) => (
              <article key={card.title}>
                <i>{card.num}</i>
                <h3>{card.title}</h3>
                <p>{card.body}</p>
              </article>
            ))}
          </div>
        </section>
        <section id="security" className="landing-security landing-container">
          <div>
            <div>
              <b>SECURITY</b>
              <h2>Honest security.</h2>
              <p>
                Real AES-256 on 7Z and ZIP. Passwords live in your macOS
                Keychain — never in our cloud, because there isn't one. Apps
                pulled from archives stay quarantined until you approve them.
              </p>
              <p>
                And when a format can't fully protect you, XZIP says so — right
                in the dialog.
              </p>
            </div>
            <SecurityCard />
          </div>
        </section>
        <section id="compare" className="landing-compare">
          <h2>How XZIP compares.</h2>
          <p>Against the built-in Archive Utility and the usual suspects.</p>
          <div className="comparison">
            <div className="comparison-head">
              <span />
              <b>XZIP</b>
              <span>BUILT-IN</span>
              <span>BETTERZIP</span>
              <span>WINZIP</span>
              <span>KEKA</span>
            </div>
            {comparisonRows.map((row) => (
              <div className="comparison-row" key={row.row}>
                <b>{row.row}</b>
                <strong>{row.xzip}</strong>
                <span>{row.builtIn}</span>
                <span>{row.betterZip}</span>
                <span>{row.winZip}</span>
                <span>{row.keka}</span>
              </div>
            ))}
          </div>
          <small>
            Verified Jul 2026 — BetterZip 5 $24.95 one-time · WinZip Mac
            Standard $38.45/year · Keka free (App Store copy supports
            development)
          </small>
        </section>
        <section className="landing-cta">
          <h2>
            Stop wrestling with archives.
            <br />
            <span>Just drag and drop.</span>
          </h2>
          <div>
            <a
              className="pill primary"
              href={downloadUrl}
              target="_blank"
              rel="noopener noreferrer"
            >
              Download XZIP
            </a>
            <GitHubBadge />
          </div>
          <small>v1.0 · 12 MB · macOS 15+ · Free &amp; open source</small>
        </section>
      </main>
      <LandingFooter />
    </div>
  )
}
