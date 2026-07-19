import { useEffect, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { downloadUrl } from '../../content/site-content'
import { formatStars, useGitHubStars } from './github-stars'

export const GITHUB_REPO = 'xmannv/xzip'
export const GITHUB_URL = `https://github.com/${GITHUB_REPO}`
// Repo starts with no stars; treat 0/loading/error as "no count yet".
const GITHUB_STARS_FALLBACK = 0

// GitHub "Octicon" mark, shared by the header icon link and the hero badge.
const GITHUB_ICON_PATH =
  'M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.27-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.46-.55.38A8.013 8.013 0 0 1 0 8c0-4.42 3.58-8 8-8Z'

/** Circular GitHub icon link for the header, matching the theme toggle. */
export function GitHubIconLink() {
  return (
    <a
      className="nav-icon"
      href={GITHUB_URL}
      target="_blank"
      rel="noopener noreferrer"
      aria-label="View XZIP on GitHub"
    >
      <svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true">
        <path d={GITHUB_ICON_PATH} />
      </svg>
    </a>
  )
}

export function Logo({ small = false }: { small?: boolean }) {
  return (
    <span className={`landing-logo ${small ? 'small' : ''}`}>
      <i aria-hidden="true">
        <b />
        <b />
        <b />
      </i>
      <strong>XZIP</strong>
    </span>
  )
}

export function GitHubBadge() {
  const stars = useGitHubStars(GITHUB_REPO, GITHUB_STARS_FALLBACK)
  const hasStars = stars > 0
  const label = formatStars(stars)
  return (
    <a
      className="github-badge"
      href={`https://github.com/${GITHUB_REPO}`}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={
        hasStars ? `XZIP on GitHub, ${label} stars` : 'View XZIP on GitHub'
      }
    >
      <svg viewBox="0 0 16 16" width="17" height="17" aria-hidden="true">
        <path d={GITHUB_ICON_PATH} />
      </svg>
      {hasStars ? (
        <>
          <i>★</i>
          {label}
        </>
      ) : (
        'View on GitHub'
      )}
    </a>
  )
}

export type ThemePreference = 'light' | 'dark' | 'system'

const THEME_STORAGE_KEY = 'xzip-theme'
const DARK_MEDIA_QUERY = '(prefers-color-scheme: dark)'
const THEME_ICONS: Record<ThemePreference, string> = {
  light: '☀',
  dark: '☾',
  system: '◐',
}

function readStoredPreference(): ThemePreference {
  try {
    const value = localStorage.getItem(THEME_STORAGE_KEY)
    return value === 'light' || value === 'dark' ? value : 'system'
  } catch {
    return 'system'
  }
}

function getSystemTheme(): 'light' | 'dark' {
  try {
    return window.matchMedia(DARK_MEDIA_QUERY).matches ? 'dark' : 'light'
  } catch {
    return 'light'
  }
}

/**
 * Shared theme preference (light / dark / system), persisted to localStorage
 * under `xzip-theme`. The resolved theme is applied to `<html data-theme>` so
 * it matches the pre-hydration inline script in __root.tsx. Used by the
 * landing page and every document page so the choice is consistent across
 * navigation.
 */
export function useTheme() {
  const [preference, setPreference] =
    useState<ThemePreference>(readStoredPreference)
  const [systemTheme, setSystemTheme] = useState<'light' | 'dark'>(
    getSystemTheme,
  )

  useEffect(() => {
    try {
      localStorage.setItem(THEME_STORAGE_KEY, preference)
    } catch {}
  }, [preference])

  useEffect(() => {
    if (preference !== 'system') return
    let media: MediaQueryList
    try {
      media = window.matchMedia(DARK_MEDIA_QUERY)
    } catch {
      return
    }
    const onChange = () => setSystemTheme(media.matches ? 'dark' : 'light')
    onChange()
    media.addEventListener('change', onChange)
    return () => media.removeEventListener('change', onChange)
  }, [preference])

  const theme = preference === 'system' ? systemTheme : preference
  useEffect(() => {
    document.documentElement.dataset.theme = theme
    document.documentElement.style.colorScheme = theme
  }, [theme])

  const cycleTheme = () =>
    setPreference((value) =>
      value === 'light' ? 'dark' : value === 'dark' ? 'system' : 'light',
    )
  return { preference, cycleTheme }
}

/**
 * Top navigation shared by the landing page and document pages.
 * `sectionsBase` prefixes the in-page anchors: '' on the landing page (same
 * document) and '/' on document pages (jump back to the home sections).
 */
export function LandingNav({
  preference,
  cycleTheme,
  sectionsBase = '',
}: {
  preference: ThemePreference
  cycleTheme: () => void
  sectionsBase?: string
}) {
  // The server doesn't know the stored preference; show the neutral system
  // icon until mounted so hydration matches the SSR markup.
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  const shown = mounted ? preference : 'system'
  const next =
    shown === 'light' ? 'dark' : shown === 'dark' ? 'system' : 'light'
  return (
    <nav className="landing-nav landing-container">
      <Link to="/" aria-label="XZIP home">
        <Logo />
      </Link>
      <div className="nav-spacer" />
      <a href={`${sectionsBase}#features`}>Features</a>
      <a href={`${sectionsBase}#security`}>Security</a>
      <a href={`${sectionsBase}#compare`}>Compare</a>
      <div className="nav-icons">
        <button
          id="theme-toggle"
          className="theme-toggle nav-icon"
          onClick={cycleTheme}
          aria-label={`Switch to ${next} theme`}
          title={`Theme: ${shown}`}
        >
          {THEME_ICONS[shown]}
        </button>
        <GitHubIconLink />
      </div>
      <a
        className="pill primary compact"
        href={downloadUrl}
        target="_blank"
        rel="noopener noreferrer"
      >
        Download
      </a>
    </nav>
  )
}

/** Site footer shared by the landing page and document pages. */
export function LandingFooter() {
  return (
    <footer className="landing-footer">
      <div className="landing-container">
        <div>
          <Logo small />
          <span />
          <Link to="/privacy">Privacy</Link>
          <Link to="/support">Support</Link>
          <Link to="/release-notes">Release notes</Link>
        </div>
      </div>
    </footer>
  )
}
