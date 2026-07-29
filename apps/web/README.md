# XZIP Web

The public XZIP product site, built with TanStack Start, React, Tailwind CSS 4, and the Cloudflare Vite plugin.

For repository architecture, native app setup, and release information, see the [root README](../../README.md).

## Commands

Run these from `apps/web`:

```bash
bun run dev              # Local Vite server on http://localhost:3000
bun run generate-routes  # Regenerate the TanStack Router route tree
bun run lint             # ESLint
bun run typecheck        # TypeScript without emitting files
bun run test             # Vitest
bun run build            # Cloudflare production bundle
bun run deploy           # Build and deploy with Wrangler
```

## Routes

- `/` — landing page
- `/privacy` — privacy policy
- `/support` — support and FAQs
- `/release-notes` — release notes

## Security headers

Security headers are applied in two places, because one file cannot cover both
kinds of response:

| Response | Headers come from | CSP `script-src` |
| --- | --- | --- |
| Server-rendered HTML (all routes) | `src/server.ts` | `'self'` + per-request nonce |
| Static assets (`dist/client`) | `public/_headers` | `'self'` |

Cloudflare applies `_headers` only to responses from the static asset handler, so
it cannot protect the documents — which is where scripts actually run. The
custom server entry exists for that.

> [!IMPORTANT]
> `main` in `wrangler.jsonc` must stay pointed at `./src/server.ts`. If it points
> at `@tanstack/react-start/server-entry` (the package default), this entry is
> never bundled and every page ships with no CSP — with no error to reveal it.

The directives live in one place, `src/security-headers.ts`. `public/_headers` is
hand-written, so `src/security-headers.test.ts` parses it and asserts it matches
`STATIC_ASSET_HEADERS` exactly. Change a directive in the module and that test
fails until `_headers` is updated too — do not edit one side alone.

### How the nonce works

The document CSP uses a nonce rather than script hashes, because TanStack Start's
hydration script embeds a per-request timestamp — its hash changes on every
response, so a hash could never match.

1. `getRouter()` mints a nonce per request with `crypto.getRandomValues`
   (server-side only).
2. TanStack applies it to the scripts it renders (hydration + module preload).
3. `__root.tsx` applies it by hand to the inline theme script, which is ours.
4. `src/server.ts` sets the matching `Content-Security-Policy` header.

`script-src` deliberately contains no `'unsafe-inline'`. `style-src` does, because
Tailwind and the 404 route emit inline `style` attributes, which cannot carry a
nonce; CSS injection cannot execute script, and `connect-src`/`img-src` bound what
it could reach, so this is an accepted tradeoff rather than an oversight.

If you add another inline script, it must receive the same nonce
(`useRouter().options.ssr?.nonce`) or the browser will block it.

`applySecurityHeaders` always emits a CSP: if the router arrives without a nonce
it mints one and writes it back before rendering, so there is no code path where a
200 response goes out unprotected. That case also logs via `console.error` in
every environment, because a silently missing CSP is the failure most worth
knowing about. Seeing that log means `ssr.nonce` in `src/router.tsx` stopped
working and should be fixed rather than left on the fallback.

To verify after changes:

```bash
bun run build && bun run preview
# CSP nonce must match the nonce on every <script> tag, and differ per request
curl -s -D - -o body.html http://localhost:4173/ | grep -i content-security-policy
grep -o 'nonce="[^"]*"' body.html
```

## Deployment

Authenticate Wrangler before the first deployment:

```bash
bunx wrangler login
bun run deploy
```

Keep secrets out of `wrangler.jsonc` and Git. Use `wrangler secret put <NAME>` when a server-side secret is required.
