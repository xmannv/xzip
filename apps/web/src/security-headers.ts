/**
 * Content-Security-Policy shared by the SSR response and `public/_headers`.
 *
 * The document CSP has to be built per request because it carries a nonce: the
 * framework's hydration script embeds a per-request timestamp, so its hash
 * differs on every response and a hash-based script-src cannot cover it.
 * A nonce sidesteps hashing entirely and keeps `'unsafe-inline'` out of
 * script-src.
 */

/** Directives that are identical for documents and static assets. */
const SHARED_DIRECTIVES = [
  "default-src 'self'",
  // Tailwind and the 404 route render inline style attributes, which cannot
  // carry a nonce. CSS injection cannot execute script, and connect-src/img-src
  // below bound what it could exfiltrate, so this is an accepted tradeoff
  // rather than an oversight.
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  // The star count and release notes read the public GitHub API.
  "connect-src 'self' https://api.github.com",
  "form-action 'self'",
  "base-uri 'none'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  'upgrade-insecure-requests',
] as const

/** Header name for the policy, used by both delivery paths. */
export const CSP_HEADER = 'Content-Security-Policy'

/**
 * Generate a fresh nonce. Uses `crypto.getRandomValues` (a CSPRNG) because a
 * guessable nonce is no protection at all: an attacker who can predict it can
 * author a script tag that the policy will accept.
 */
export function createCspNonce(): string {
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  // base64 keeps the value inside the nonce charset the CSP grammar allows.
  return btoa(String.fromCharCode(...bytes))
}

/**
 * Build the document CSP for a single response. `nonce` is required, not
 * optional: a document policy without one would block the inline theme and
 * hydration scripts and white-screen the page, so there is no valid way to
 * call this without a nonce.
 */
export function buildContentSecurityPolicy(nonce: string): string {
  // No 'unsafe-inline' in script-src: every inline script we emit carries the
  // nonce, so allowing unsafe-inline would defeat the point of having a CSP.
  return [`script-src 'self' 'nonce-${nonce}'`, ...SHARED_DIRECTIVES].join('; ')
}

/**
 * CSP for static assets served by Cloudflare's asset handler. Nothing under
 * `dist/client` is an inline script, so plain `'self'` needs no nonce.
 */
export const STATIC_ASSET_CSP: string = [
  "script-src 'self'",
  ...SHARED_DIRECTIVES,
].join('; ')

/**
 * Minimal shape of the bits of the router this module touches. Declared
 * structurally so the header logic stays unit-testable without constructing a
 * real router.
 */
export interface NonceCarrier {
  options: { ssr?: { nonce?: string } }
}

export interface AppliedSecurityHeaders {
  nonce: string
  /** True when the router arrived without a nonce and this call supplied one. */
  recovered: boolean
}

/**
 * Apply every security header for a server-rendered document.
 *
 * Deliberately cannot leave the response without a CSP. If the router has no
 * nonce, one is minted here and written back to the router *before* rendering,
 * so the scripts and the header still agree. The alternatives are both worse:
 * skipping the CSP fails open silently, and emitting a nonce-less document
 * policy would block hydration and white-screen the page.
 *
 * Call before rendering. Mutating `options` mid-request follows what the start
 * handler itself does (it assigns `options.additionalContext` the same way).
 */
export function applySecurityHeaders(
  router: NonceCarrier,
  headers: Headers,
): AppliedSecurityHeaders {
  for (const [name, value] of Object.entries(STATIC_SECURITY_HEADERS)) {
    headers.set(name, value)
  }

  const existing = router.options.ssr?.nonce
  const nonce = existing ?? createCspNonce()
  if (existing === undefined) {
    router.options.ssr = { ...router.options.ssr, nonce }
  }

  headers.set(CSP_HEADER, buildContentSecurityPolicy(nonce))
  return { nonce, recovered: existing === undefined }
}

/** Security headers that are identical for every response. */
export const STATIC_SECURITY_HEADERS: Record<string, string> = {
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'geolocation=(), microphone=(), camera=()',
}

/**
 * Every header `public/_headers` is expected to declare. Exported so a test can
 * assert the hand-written file still matches this module: the two delivery
 * paths would otherwise drift silently when a directive changes here.
 */
export const STATIC_ASSET_HEADERS: Record<string, string> = {
  ...STATIC_SECURITY_HEADERS,
  [CSP_HEADER]: STATIC_ASSET_CSP,
}
