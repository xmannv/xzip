import { Link, createRouter as createTanStackRouter } from '@tanstack/react-router'
import { routeTree } from './routeTree.gen'

function NotFound() {
  return (
    <main
      style={{
        minHeight: '100vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '1rem',
        padding: '2rem',
        textAlign: 'center',
        background: 'var(--nf-bg)',
        color: 'var(--nf-fg)',
        fontFamily:
          '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
      }}
    >
      <p style={{ fontSize: '0.875rem', letterSpacing: '0.08em', color: 'var(--nf-muted)', margin: 0 }}>
        404
      </p>
      <h1 style={{ fontSize: '2rem', fontWeight: 600, margin: 0 }}>Page not found</h1>
      <p style={{ color: 'var(--nf-muted)', maxWidth: '28rem', margin: 0 }}>
        The page you're looking for doesn't exist or may have been moved.
      </p>
      <Link
        to="/"
        style={{
          marginTop: '0.5rem',
          padding: '0.625rem 1.25rem',
          borderRadius: '980px',
          background: '#0071e3',
          color: '#fff',
          textDecoration: 'none',
          fontWeight: 500,
        }}
      >
        Back to home
      </Link>
    </main>
  )
}

export function getRouter() {
  const router = createTanStackRouter({
    routeTree,
    scrollRestoration: true,
    defaultPreload: 'intent',
    defaultPreloadStaleTime: 0,
    defaultNotFoundComponent: NotFound,
  })

  return router
}

declare module '@tanstack/react-router' {
  interface Register {
    router: ReturnType<typeof getRouter>
  }
}
