import {
  LandingFooter,
  LandingNav,
  useTheme,
} from '../features/landing/landing-chrome'

/**
 * Shared layout for document pages (Privacy, Support, Release Notes).
 * Reuses the landing page's nav, footer, and theme toggle so the whole site
 * shares one chrome. Section links jump back to the home page anchors.
 */
export function DocumentLayout({
  eyebrow,
  title,
  intro,
  children,
}: {
  eyebrow?: string
  title: string
  intro: string
  children: React.ReactNode
}) {
  const { preference, cycleTheme } = useTheme()
  return (
    <div className="landing-root">
      <LandingNav
        preference={preference}
        cycleTheme={cycleTheme}
        sectionsBase="/"
      />
      <main className="doc landing-container">
        {eyebrow ? <p className="doc-eyebrow">{eyebrow}</p> : null}
        <h1>{title}</h1>
        <p className="doc-intro">{intro}</p>
        <div className="doc-body">{children}</div>
      </main>
      <LandingFooter />
    </div>
  )
}
