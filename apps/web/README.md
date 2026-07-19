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

## Deployment

Authenticate Wrangler before the first deployment:

```bash
bunx wrangler login
bun run deploy
```

Keep secrets out of `wrangler.jsonc` and Git. Use `wrangler secret put <NAME>` when a server-side secret is required.
