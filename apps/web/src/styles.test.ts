import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

const css = readFileSync(new URL('./styles.css', import.meta.url), 'utf8')

const globalReducedMotion = `@media (prefers-reduced-motion: reduce) {
  html {
    scroll-behavior: auto;
  }
  *,
  *:before,
  *:after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}`

const landingReducedMotion = `@media (prefers-reduced-motion: reduce) {
  .landing-root * {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}`

describe('global stylesheet contracts', () => {
  it('keeps document-wide reduced-motion behavior', () => {
    expect(css).toContain(globalReducedMotion)
    expect(css).toContain(landingReducedMotion)
  })

  it('keeps deleted legacy landing selectors absent', () => {
    const legacySelectors = [
      /(^|[},])\s*\.site-header(?=[\s,{:#>+~])/m,
      /(^|[},])\s*\.nav-wrap(?=[\s,{:#>+~])/m,
      /(^|[},])\s*\.hero(?=[\s,{:#>+~])/m,
      /(^|[},])\s*\.eyebrow(?=[\s,{:#>+~])/m,
      /(^|[},])\s*\.app-window(?=[\s,{:#>+~])/m,
    ]

    for (const selector of legacySelectors) {
      expect(css).not.toMatch(selector)
    }
  })
})
