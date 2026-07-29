import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  CSP_HEADER,
  STATIC_ASSET_CSP,
  STATIC_ASSET_HEADERS,
  STATIC_SECURITY_HEADERS,
  applySecurityHeaders,
  buildContentSecurityPolicy,
  createCspNonce,
} from './security-headers'
import { getRouter } from './router'

describe('createCspNonce', () => {
  it('returns 16 bytes of base64', () => {
    expect(atob(createCspNonce())).toHaveLength(16)
  })

  it('returns a different value every call', () => {
    // A predictable nonce is no protection: an attacker who can guess it can
    // author a script tag the policy accepts.
    const seen = new Set(Array.from({ length: 100 }, () => createCspNonce()))
    expect(seen.size).toBe(100)
  })

  it('stays inside the CSP nonce charset', () => {
    for (let i = 0; i < 50; i++) {
      expect(createCspNonce()).toMatch(/^[A-Za-z0-9+/]+={0,2}$/)
    }
  })
})

describe('buildContentSecurityPolicy', () => {
  const csp = buildContentSecurityPolicy('TESTNONCE')

  it('allows scripts only via self and the nonce', () => {
    expect(csp).toContain("script-src 'self' 'nonce-TESTNONCE'")
  })

  it("never allows 'unsafe-inline' for scripts", () => {
    // Would defeat the whole policy, so assert on the directive itself rather
    // than the string as a whole (style-src legitimately uses it).
    const scriptSrc = csp.split(';').find((d) => d.includes('script-src'))
    expect(scriptSrc).not.toContain('unsafe-inline')
  })

  it("never allows 'unsafe-eval'", () => {
    expect(csp).not.toContain('unsafe-eval')
  })

  it('locks down the dangerous fetch directives', () => {
    expect(csp).toContain("object-src 'none'")
    expect(csp).toContain("base-uri 'none'")
    expect(csp).toContain("frame-ancestors 'none'")
    expect(csp).toContain("default-src 'self'")
  })

  it('permits the GitHub API the landing page calls', () => {
    expect(csp).toContain("connect-src 'self' https://api.github.com")
  })

  it('embeds the exact nonce it was given', () => {
    expect(buildContentSecurityPolicy('abc/+=')).toContain("'nonce-abc/+='")
  })
})

describe('STATIC_ASSET_CSP', () => {
  it("allows no inline script at all, since dist/client has none", () => {
    const scriptSrc = STATIC_ASSET_CSP.split(';').find((d) =>
      d.includes('script-src'),
    )
    expect(scriptSrc?.trim()).toBe("script-src 'self'")
    expect(STATIC_ASSET_CSP).not.toContain('nonce-')
  })

  it('differs from the document CSP only in script-src', () => {
    const rest = (csp: string) =>
      csp
        .split(';')
        .map((d) => d.trim())
        .filter((d) => !d.startsWith('script-src'))
    expect(rest(STATIC_ASSET_CSP)).toEqual(rest(buildContentSecurityPolicy('N')))
  })
})

describe('applySecurityHeaders', () => {
  it('uses the nonce the router already carries', () => {
    const router = { options: { ssr: { nonce: 'FROMROUTER' } } }
    const headers = new Headers()
    const result = applySecurityHeaders(router, headers)

    expect(result).toEqual({ nonce: 'FROMROUTER', recovered: false })
    expect(headers.get(CSP_HEADER)).toContain("'nonce-FROMROUTER'")
  })

  it('sets every static security header', () => {
    const headers = new Headers()
    applySecurityHeaders({ options: { ssr: { nonce: 'N' } } }, headers)
    for (const [name, value] of Object.entries(STATIC_SECURITY_HEADERS)) {
      expect(headers.get(name)).toBe(value)
    }
  })

  // The point of the helper: no input leaves the response without a CSP.
  it.each([
    ['missing ssr option', { options: {} }],
    ['missing nonce', { options: { ssr: {} } }],
    ['undefined nonce', { options: { ssr: { nonce: undefined } } }],
  ])('still sets a CSP when the router has %s', (_label, router) => {
    const headers = new Headers()
    const result = applySecurityHeaders(router, headers)

    expect(result.recovered).toBe(true)
    expect(headers.get(CSP_HEADER)).toContain(`'nonce-${result.nonce}'`)
  })

  it('writes the recovered nonce back so the scripts match the header', () => {
    // Without this, a fallback nonce would be in the header but not on the
    // scripts, and the browser would block them.
    const router: { options: { ssr?: { nonce?: string } } } = { options: {} }
    const headers = new Headers()
    const { nonce } = applySecurityHeaders(router, headers)

    expect(router.options.ssr?.nonce).toBe(nonce)
  })

  it('preserves other ssr options when recovering', () => {
    const router = { options: { ssr: { other: true } } } as unknown as {
      options: { ssr?: { nonce?: string } }
    }
    applySecurityHeaders(router, new Headers())
    expect(router.options.ssr).toMatchObject({ other: true })
  })
})

describe('getRouter', () => {
  // src/server.ts relies on this: it is the only reason `recovered` should
  // never be true in production. Nothing else guards the invariant.
  it('always supplies an SSR nonce in a server environment', () => {
    expect(typeof document).toBe('undefined')
    for (let i = 0; i < 5; i++) {
      expect(getRouter().options.ssr?.nonce).toMatch(/^[A-Za-z0-9+/]+={0,2}$/)
    }
  })

  it('mints a distinct nonce per router (i.e. per request)', () => {
    const a = getRouter().options.ssr?.nonce
    const b = getRouter().options.ssr?.nonce
    expect(a).toBeDefined()
    expect(a).not.toBe(b)
  })
})

describe('public/_headers', () => {
  const raw = readFileSync(
    join(import.meta.dirname, '..', 'public', '_headers'),
    'utf8',
  )

  /** Parse the `Name: value` lines from the single `/*` rule block. */
  const parsed = Object.fromEntries(
    raw
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#') && !line.startsWith('/'))
      .map((line) => {
        const at = line.indexOf(':')
        return [line.slice(0, at).trim(), line.slice(at + 1).trim()]
      }),
  )

  it('applies its rules to every path', () => {
    expect(raw).toMatch(/^\/\*$/m)
  })

  // This is the anti-drift check: _headers is hand-written, so without it a
  // directive change in security-headers.ts would silently apply to documents
  // only, leaving static assets on a stale policy.
  it('matches STATIC_ASSET_HEADERS exactly', () => {
    expect(parsed).toEqual(STATIC_ASSET_HEADERS)
  })

  it('does not carry a nonce, which a static file cannot rotate', () => {
    expect(parsed[CSP_HEADER]).not.toContain('nonce-')
  })
})
