import { useEffect, useState } from 'react'

export type ReleaseItemKind = 'New' | 'Fixed' | 'Improved'

export type ReleaseItem = {
  kind: ReleaseItemKind
  text: string
}

export type ReleaseNote = {
  /** Stable, unique React key (the git tag, or an index fallback). */
  key: string
  version: string
  date: string
  tag: string
  latest: boolean
  items: ReleaseItem[]
}

export type ReleasesState = {
  status: 'loading' | 'ready' | 'empty' | 'error'
  releases: ReleaseNote[]
  /** True while showing cached data that is being revalidated in the background. */
  stale: boolean
}

type GitHubRelease = {
  tag_name?: string
  name?: string
  body?: string
  published_at?: string
  prerelease?: boolean
  draft?: boolean
}

const dateFormatter = new Intl.DateTimeFormat('en-US', {
  year: 'numeric',
  month: 'long',
  day: 'numeric',
})

function formatDate(iso: string | undefined): string {
  if (!iso) return ''
  const parsed = new Date(iso)
  return Number.isNaN(parsed.getTime()) ? '' : dateFormatter.format(parsed)
}

/**
 * Infer a changelog badge from a bullet's leading marker or wording.
 * GitHub release bodies are free-form Markdown, so we key off common
 * conventions: an explicit "Fixed:"/"Added:" prefix, or verbs like "fix".
 */
export function classify(text: string): ReleaseItemKind {
  const lower = text.toLowerCase()
  // Match the "fix"/"bug" family as whole words only, so substrings like
  // "prefix"/"suffix" are never mislabeled as fixes.
  if (/\b(fix|fixed|fixes|fixing|bug|bugfix)\b/.test(lower)) return 'Fixed'
  if (/^(improve|improved|update|updated|change|changed|refine)\b/.test(lower))
    return 'Improved'
  return 'New'
}

/**
 * Map an explicit "**Kind:**" changelog label to a badge, or null when the
 * label is not a recognized kind (the wording is then classified instead).
 */
function labelKind(label: string): ReleaseItemKind | null {
  const lower = label.toLowerCase()
  if (/^(fix|fixed|bug|bugfix)/.test(lower)) return 'Fixed'
  if (/^(improve|improved|update|updated|change|changed|refine)/.test(lower))
    return 'Improved'
  if (/^(add|added|new)/.test(lower)) return 'New'
  return null
}

/** Extract bullet lines from a Markdown release body. */
function parseItems(body: string | undefined): ReleaseItem[] {
  if (!body) return []
  return body
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => /^[-*]\s+/.test(line))
    .map((line) => {
      const withoutBullet = line.replace(/^[-*]\s+/, '')
      // A leading "**Kind:**" label decides the badge. Read it BEFORE stripping
      // it: otherwise an explicit "**Fixed:**" whose remaining wording reads like
      // an improvement (e.g. "**Fixed:** improved retry logic") is mislabeled.
      const label = withoutBullet.match(/^\*\*(.+?)\*\*:?\s*/)
      const text = (label ? withoutBullet.slice(label[0].length) : withoutBullet).trim()
      const kind = (label && labelKind(label[1])) || classify(text)
      return { kind, text }
    })
    .filter((item) => item.text.length > 0)
}

export function normalize(releases: GitHubRelease[]): ReleaseNote[] {
  const published = releases.filter((release) => !release.draft)
  // GitHub returns releases newest-first. The LATEST badge belongs to the
  // newest stable (non-prerelease) release so a prerelease sorting first can't
  // steal it; if every release is a prerelease, fall back to the newest one.
  const stableIndex = published.findIndex((release) => !release.prerelease)
  const latestIndex = stableIndex === -1 ? 0 : stableIndex
  return published.map((release, index) => {
    const version =
      release.name?.trim() || release.tag_name?.trim() || 'Release'
    const isLatest = index === latestIndex
    return {
      // Git tags are unique per repo; index keeps keys unique when absent.
      key: release.tag_name?.trim() || `release-${index}`,
      version,
      date: formatDate(release.published_at),
      tag: isLatest ? 'LATEST' : release.prerelease ? 'BETA' : 'RELEASE',
      latest: isLatest,
      items: parseItems(release.body),
    }
  })
}

// Keyed by `repo` so two different repositories never share cached releases.
const cached = new Map<string, ReleaseNote[]>()
const inflight = new Map<string, Promise<ReleaseNote[] | null>>()

// Persist releases across reloads/tabs so returning visitors see content
// instantly (stale-while-revalidate) instead of a loading state. The GitHub
// public API is rate-limited (60 req/h/IP), so caching also avoids waste.
const STORAGE_KEY_PREFIX = 'xzip-releases'
const storageKey = (repo: string) => `${STORAGE_KEY_PREFIX}:${repo}`
const TTL_MS = 30 * 60 * 1000 // 30 minutes

type StoredCache = { at: number; releases: ReleaseNote[] }

/**
 * Defensive shape check for one cached release. localStorage can hold data
 * written by an older schema, so we validate every required field and discard
 * the whole cache on any drift rather than letting a bad payload crash render.
 */
function isReleaseNote(value: unknown): value is ReleaseNote {
  if (typeof value !== 'object' || value === null) return false
  const note = value as Record<string, unknown>
  return (
    typeof note.key === 'string' &&
    typeof note.version === 'string' &&
    typeof note.date === 'string' &&
    typeof note.tag === 'string' &&
    typeof note.latest === 'boolean' &&
    Array.isArray(note.items) &&
    note.items.every((item) => {
      if (typeof item !== 'object' || item === null) return false
      const entry = item as Record<string, unknown>
      return typeof entry.kind === 'string' && typeof entry.text === 'string'
    })
  )
}

export function readStored(repo: string): StoredCache | null {
  try {
    const raw = localStorage.getItem(storageKey(repo))
    if (!raw) return null
    const parsed = JSON.parse(raw) as unknown
    if (typeof parsed !== 'object' || parsed === null) return null
    const candidate = parsed as Record<string, unknown>
    if (
      typeof candidate.at !== 'number' ||
      !Array.isArray(candidate.releases) ||
      !candidate.releases.every(isReleaseNote)
    ) {
      return null
    }
    return { at: candidate.at, releases: candidate.releases }
  } catch {
    return null
  }
}

function writeStored(repo: string, releases: ReleaseNote[]) {
  try {
    localStorage.setItem(
      storageKey(repo),
      JSON.stringify({ at: Date.now(), releases } satisfies StoredCache),
    )
  } catch {}
}

async function fetchReleases(repo: string): Promise<ReleaseNote[] | null> {
  try {
    const response = await fetch(
      `https://api.github.com/repos/${repo}/releases`,
      {
        headers: { Accept: 'application/vnd.github+json' },
        // Don't let a stalled connection hang the skeleton forever (and keep the
        // shared inflight promise pending); abort after 8s so it can retry.
        signal: AbortSignal.timeout(8000),
      },
    )
    if (!response.ok) return null
    const data = (await response.json()) as unknown
    if (!Array.isArray(data)) return null
    return normalize(data as GitHubRelease[])
  } catch {
    return null
  }
}

/**
 * Reads published releases for `repo` from the public GitHub API and shapes
 * them for the release-notes page.
 *
 * Strategy: stale-while-revalidate. On first paint we hydrate from an in-memory
 * or localStorage cache (marked `stale`) so content shows immediately, then
 * revalidate in the background and swap in fresh data. Only shows the `loading`
 * state when there is nothing cached at all. Shares one request across
 * instances and distinguishes "empty" (no releases yet) from "error".
 */
export function useGitHubReleases(repo: string): ReleasesState {
  // SSR-safe initial state: only the in-memory cache (null on the server and
  // on a fresh client load, so hydration matches). localStorage is read in the
  // effect below, which runs on the client only.
  const [state, setState] = useState<ReleasesState>(() => {
    const memo = cached.get(repo)
    return memo
      ? { status: memo.length ? 'ready' : 'empty', releases: memo, stale: true }
      : { status: 'loading', releases: [], stale: false }
  })

  useEffect(() => {
    const stored = readStored(repo)
    const fresh = stored !== null && Date.now() - stored.at < TTL_MS
    // Cache is fresh enough: use it as-is, skip the network round-trip.
    if (fresh && stored) {
      cached.set(repo, stored.releases)
      setState({
        status: stored.releases.length ? 'ready' : 'empty',
        releases: stored.releases,
        stale: false,
      })
      return
    }

    // Expired cache still present: paint it immediately (marked stale) and seed
    // the in-memory cache so a returning visitor never sees a skeleton, then
    // revalidate below. If the fetch fails we keep this stale data, not an error.
    if (stored) {
      cached.set(repo, stored.releases)
      setState({
        status: stored.releases.length ? 'ready' : 'empty',
        releases: stored.releases,
        stale: true,
      })
    }

    let active = true
    if (!inflight.has(repo)) inflight.set(repo, fetchReleases(repo))
    inflight.get(repo)!.then((value) => {
      inflight.delete(repo)
      if (!active) return
      if (value === null) {
        // Network failed: keep showing any cached data rather than an error.
        setState((prev) =>
          prev.releases.length || cached.has(repo)
            ? { ...prev, stale: false }
            : { status: 'error', releases: [], stale: false },
        )
        return
      }
      cached.set(repo, value)
      writeStored(repo, value)
      setState({
        status: value.length ? 'ready' : 'empty',
        releases: value,
        stale: false,
      })
    })
    return () => {
      active = false
    }
  }, [repo])

  return state
}
