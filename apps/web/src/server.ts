import {
  createStartHandler,
  defaultStreamHandler,
} from '@tanstack/react-start/server'
import { applySecurityHeaders } from './security-headers'

/**
 * Custom server entry: adds the security headers to server-rendered HTML.
 *
 * `public/_headers` cannot do this. Cloudflare applies that file only to
 * responses from the static asset handler, and every route's HTML is rendered
 * here in the Worker, so without this entry the document CSP would never reach
 * the pages where scripts actually run.
 *
 * NOTE: `wrangler.jsonc` must point `main` at this file. If it points at
 * `@tanstack/react-start/server-entry` instead, none of this runs and the pages
 * ship with no CSP at all.
 */
const fetch = createStartHandler((ctx) => {
  // Runs before defaultStreamHandler so a recovered nonce still reaches the
  // scripts. Always sets a CSP, so there is no path where a 200 response goes
  // out unprotected.
  const { recovered } = applySecurityHeaders(ctx.router, ctx.responseHeaders)

  if (recovered) {
    // Unconditional, including production: losing the router-minted nonce means
    // getRouter() stopped supplying one, and a silently degraded security
    // posture is exactly the kind of thing that goes unnoticed for months.
    console.error(
      '[security-headers] Router supplied no SSR nonce; generated a fallback. ' +
        'Check the ssr.nonce option in src/router.tsx.',
    )
  }

  return defaultStreamHandler(ctx)
})

export default { fetch }
