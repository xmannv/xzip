import {
  HeadContent,
  Scripts,
  createRootRoute,
  useRouterState,
} from '@tanstack/react-router'
import appCss from '../styles.css?url'

const SITE_URL = 'https://xzip.dev'

export const Route = createRootRoute({
  head: () => ({
    links: [
      { rel: 'stylesheet', href: appCss },
      { rel: 'icon', href: '/favicon.ico' },
      { rel: 'manifest', href: '/manifest.json' },
      { rel: 'apple-touch-icon', href: '/logo192.png' },
    ],
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title: 'XZIP — The archive utility macOS deserves' },
      {
        name: 'description',
        content:
          'XZIP is the archive utility macOS deserves — fast, private, and native.',
      },
      { name: 'referrer', content: 'strict-origin-when-cross-origin' },
      { name: 'color-scheme', content: 'light dark' },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: 'XZIP' },
      {
        property: 'og:title',
        content: 'XZIP — The archive utility macOS deserves',
      },
      {
        property: 'og:description',
        content:
          'XZIP is the archive utility macOS deserves — fast, private, and native.',
      },
      { property: 'og:image', content: 'https://xzip.dev/og-image.png' },
      { property: 'og:image:width', content: '1200' },
      { property: 'og:image:height', content: '630' },
      { name: 'twitter:card', content: 'summary_large_image' },
      {
        name: 'twitter:title',
        content: 'XZIP — The archive utility macOS deserves',
      },
      {
        name: 'twitter:description',
        content:
          'XZIP is the archive utility macOS deserves — fast, private, and native.',
      },
      { name: 'twitter:image', content: 'https://xzip.dev/og-image.png' },
    ],
  }),
  shellComponent: RootDocument,
})

// Applies the stored/system theme before first paint so a dark-mode visitor
// never sees a light flash. Must mirror the resolution logic in useTheme.
const themeInitScript = `try{var p=localStorage.getItem('xzip-theme');var t=p==='light'||p==='dark'?p:matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';var d=document.documentElement;d.dataset.theme=t;d.style.colorScheme=t}catch(e){}`

function RootDocument({ children }: { children: React.ReactNode }) {
  // Reflect the current route in the canonical link and og:url so every page
  // advertises its own URL instead of the homepage.
  const pathname = useRouterState({
    select: (state) => state.location.pathname,
  })
  const canonical = `${SITE_URL}${pathname}`
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
        <link rel="canonical" href={canonical} />
        <meta property="og:url" content={canonical} />
        {/* Literal tags: HeadContent dedupes head() meta by name, which would
            drop one of the two media-scoped theme-color variants. */}
        <meta
          name="theme-color"
          media="(prefers-color-scheme: light)"
          content="#fbfbfd"
        />
        <meta
          name="theme-color"
          media="(prefers-color-scheme: dark)"
          content="#101013"
        />
        <script dangerouslySetInnerHTML={{ __html: themeInitScript }} />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
