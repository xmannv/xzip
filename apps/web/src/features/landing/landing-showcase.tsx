import { useEffect, useRef, useState } from 'react'
import { archiveRows, showcaseSlides } from './landing-data'

function TrafficLights() {
  return (
    <span className="landing-lights" aria-hidden="true">
      <i />
      <i />
      <i />
    </span>
  )
}

/** Shared archive title used by the hero and the browse showcase preview. */
export function ArchivePreviewTitle() {
  return (
    <span className="archive-title">
      <i>ZIP</i>
      <b>Project Assets.zip</b>
      <small>9 items · 48.2 MB · AES-256</small>
    </span>
  )
}

/** Shared table header + rows; wrappers/toolbars differ intentionally per use. */
export function ArchivePreviewRows() {
  return (
    <>
      <div className="demo-head">
        <i /> <span>Name</span>
        <span>Size</span>
        <span>Kind</span>
      </div>
      {archiveRows.map((row, index) => (
        <div
          className={`demo-row ${row.selected ? 'selected' : index % 2 ? 'stripe' : ''}`}
          key={row.name}
        >
          <i style={{ background: row.icon }}>{row.ext}</i>
          <b>{row.name}</b>
          <span>{row.size}</span>
          <span>{row.kind}</span>
        </div>
      ))}
    </>
  )
}
function BrowsePreview() {
  return (
    <div className="demo-window browse-demo">
      <div className="demo-toolbar">
        <TrafficLights />
        <ArchivePreviewTitle />
        <strong>Extract</strong>
      </div>
      <ArchivePreviewRows />
      <small>9 items · 48.2 MB compressed · 96.7 MB unpacked</small>
    </div>
  )
}
function DropPreview() {
  return (
    <div className="demo-window drop-demo">
      <div className="demo-toolbar">
        <TrafficLights />
        <b>XZIP</b>
        <span>Format: ZIP ▾</span>
      </div>
      <div className="drop-zones">
        <div>
          <i>↓</i>
          <b>Drop files to compress</b>
          <small>or click to browse</small>
        </div>
        <div>
          <i>↑</i>
          <b>Drop an archive to extract</b>
          <small>ZIP · 7Z · RAR · DMG + 27 more</small>
        </div>
      </div>
      <small>Dragging onto the Dock icon works too — no window needed</small>
    </div>
  )
}
function CompressPreview() {
  return (
    <div className="demo-window compress-demo">
      <div>
        <b>New Archive</b>
        <span>Preset: Default ▾</span>
      </div>
      <div className="segmented">
        <span>ZIP</span>
        <b>7Z</b>
        <span>TAR.GZ</span>
        <span>DMG</span>
      </div>
      <div className="compress-meta">
        <b>Compression</b>
        <em>~ 46 MB · −52%</em>
      </div>
      <div className="slider-row">
        <small>Faster</small>
        <div className="slider">
          <i />
        </div>
        <small>Smaller</small>
      </div>
      <div className="encrypt-card">
        <div>
          <span className="toggle" />
          <b>Encrypt with password</b>
          <small>AES-256</small>
        </div>
        <div>
          <code>••••••••••••</code>
          <button type="button">Suggest</button>
        </div>
      </div>
      <div className="demo-actions">
        <span>Cancel</span>
        <b>Create</b>
      </div>
    </div>
  )
}
function QueuePreview() {
  return (
    <div className="demo-window queue-demo">
      <div className="demo-toolbar">
        <TrafficLights />
        <b>Queue</b>
        <span>2 running · 1 done</span>
      </div>
      {[
        ['RAR', '#af52de', 'Extracting Photos-2026.rar', '64% · 41 s', '64%'],
        [
          '7Z',
          '#ff9f0a',
          'Compressing Client Handoff.7z',
          '28% · 2 min',
          '28%',
        ],
      ].map((r) => (
        <div className="queue-row" key={r[2]}>
          <b style={{ background: r[1] }}>{r[0]}</b>
          <span>{r[2]}</span>
          <small>{r[3]}</small>
          <i>
            <i style={{ width: r[4] }} />
          </i>
        </div>
      ))}
      <div className="queue-done">
        <b>✓</b>
        <span>Extracted design-kit.zip → Downloads</span>
        <em>Reveal</em>
      </div>
    </div>
  )
}
function FinderPreview() {
  return (
    <div className="finder-demo">
      <div>
        <span>Open</span>
        <span>
          Open With<em>›</em>
        </span>
        <i />
        <span className="active">
          XZIP<em>›</em>
        </span>
        <i />
        <span>Get Info</span>
        <span>Move to Trash</span>
      </div>
      <div>
        <span>Compress to “Designs.zip”</span>
        <span>Compress to 7Z…</span>
        <i />
        <span>Extract Here</span>
        <span>Extract to Downloads</span>
        <i />
        <small>Presets</small>
        <span>Share-friendly ZIP</span>
        <span>Max compression 7Z + AES</span>
      </div>
    </div>
  )
}
const previews = [
  BrowsePreview,
  DropPreview,
  CompressPreview,
  QueuePreview,
  FinderPreview,
]

export function LandingShowcase() {
  const [active, setActive] = useState(0)
  const [auto, setAuto] = useState(true)
  const tablistRef = useRef<HTMLDivElement>(null)
  // Keep the active tab centered when it changes (auto-advance or click).
  // Scroll only the tablist itself (never scrollIntoView, which could jump the
  // whole page). No-op on desktop where the tablist doesn't overflow.
  useEffect(() => {
    const container = tablistRef.current
    const tab = container?.children[active] as HTMLElement | undefined
    if (!container || !tab) return
    const containerRect = container.getBoundingClientRect()
    const tabRect = tab.getBoundingClientRect()
    const delta =
      tabRect.left -
      containerRect.left -
      (container.clientWidth - tab.clientWidth) / 2
    // Guard: scrollBy is unimplemented in jsdom (tests) and older engines.
    if (typeof container.scrollBy === 'function') {
      const behavior =
        typeof window.matchMedia === 'function' &&
        window.matchMedia('(prefers-reduced-motion: reduce)').matches
          ? 'auto'
          : 'smooth'
      container.scrollBy({ left: delta, behavior })
    }
  }, [active])
  useEffect(() => {
    if (!auto) return
    // Respect users who prefer reduced motion: don't auto-advance for them.
    const allowsMotion =
      typeof window.matchMedia !== 'function' ||
      window.matchMedia('(prefers-reduced-motion: no-preference)').matches
    if (!allowsMotion) return
    const timer = window.setInterval(
      () => setActive((value) => (value + 1) % showcaseSlides.length),
      6000,
    )
    return () => window.clearInterval(timer)
  }, [auto])
  const pick = (index: number) => {
    setActive((index + showcaseSlides.length) % showcaseSlides.length)
    setAuto(false)
  }
  // Roving tab navigation (WAI-ARIA tabs pattern): arrows move and activate.
  const onTabKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const count = showcaseSlides.length
    let next = active
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown')
      next = (active + 1) % count
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp')
      next = (active - 1 + count) % count
    else if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = count - 1
    else return
    event.preventDefault()
    pick(next)
    const tab = tablistRef.current?.children[next] as HTMLElement | undefined
    tab?.focus()
  }
  const slide = showcaseSlides[active]
  const Preview = previews[active]
  return (
    <section
      className="landing-showcase landing-container"
      aria-labelledby="showcase-heading"
    >
      <header>
        <h2 id="showcase-heading">Five screens. That's the whole app.</h2>
        <p>
          No wizard mazes, no toolbar walls. Every screen explains itself — you
          already know how to use it.
        </p>
      </header>
      <div
        className="showcase-tabs"
        role="tablist"
        ref={tablistRef}
        onKeyDown={onTabKeyDown}
      >
        {showcaseSlides.map((item, index) => (
          <button
            id={`showcase-tab-${index}`}
            role="tab"
            aria-selected={index === active}
            aria-controls="showcase-panel"
            tabIndex={index === active ? 0 : -1}
            onClick={() => pick(index)}
            key={item.label}
          >
            {item.label}
          </button>
        ))}
      </div>
      <div className="showcase-stage">
        <div className="showcase-copy">
          <b>{slide.tag}</b>
          <h3>{slide.title}</h3>
          <p>{slide.body}</p>
          <small>{slide.note}</small>
          <div>
            <button
              aria-label="Previous showcase"
              onClick={() => pick(active - 1)}
            >
              ←
            </button>
            <button aria-label="Next showcase" onClick={() => pick(active + 1)}>
              →
            </button>
            <span>0{active + 1} / 05</span>
          </div>
        </div>
        <div
          id="showcase-panel"
          className="showcase-preview"
          role="tabpanel"
          aria-labelledby={`showcase-tab-${active}`}
        >
          <Preview />
        </div>
      </div>
    </section>
  )
}
