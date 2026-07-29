import { useEffect, useState } from 'react'

/** GitHub-style compact star count, e.g. 4234 -> "4.2k". */
export function formatStars(count: number): string {
  if (count >= 1000) {
    return `${(count / 1000).toFixed(1).replace(/\.0$/, '')}k`
  }
  return String(count)
}

// Keyed by `repo` so two different repositories never share a cached count.
const cached = new Map<string, number>()
const inflight = new Map<string, Promise<number | null>>()

// Persist across reloads/tabs: the public GitHub API is rate-limited
// (60 req/h/IP), so a returning visitor should not spend a request on a number
// that barely changes. Mirrors the caching in github-releases.ts.
const STORAGE_KEY_PREFIX = 'xzip-stars'
const storageKey = (repo: string) => `${STORAGE_KEY_PREFIX}:${repo}`
const TTL_MS = 30 * 60 * 1000 // 30 minutes

type StoredCache = { at: number; count: number }

export function readStored(repo: string): StoredCache | null {
  try {
    const raw = localStorage.getItem(storageKey(repo))
    if (!raw) return null
    const parsed = JSON.parse(raw) as unknown
    if (typeof parsed !== 'object' || parsed === null) return null
    const candidate = parsed as Record<string, unknown>
    // localStorage can hold data written by an older schema, so validate both
    // fields and discard the whole entry on any drift.
    if (
      typeof candidate.at !== 'number' ||
      typeof candidate.count !== 'number'
    ) {
      return null
    }
    return { at: candidate.at, count: candidate.count }
  } catch {
    return null
  }
}

function writeStored(repo: string, count: number) {
  try {
    localStorage.setItem(
      storageKey(repo),
      JSON.stringify({ at: Date.now(), count } satisfies StoredCache),
    )
  } catch {}
}

async function fetchStarCount(repo: string): Promise<number | null> {
  try {
    const response = await fetch(`https://api.github.com/repos/${repo}`, {
      headers: { Accept: 'application/vnd.github+json' },
      // Don't let a stalled connection keep the shared inflight promise pending
      // forever; abort after 8s so a later mount can retry.
      signal: AbortSignal.timeout(8000),
    })
    if (!response.ok) return null
    const data = (await response.json()) as { stargazers_count?: unknown }
    return typeof data.stargazers_count === 'number'
      ? data.stargazers_count
      : null
  } catch {
    return null
  }
}

/**
 * Reads the live star count for `repo` from the public GitHub API.
 * Falls back to `fallback` while loading or when the request fails, and
 * shares a single request across every component instance.
 */
export function useGitHubStars(repo: string, fallback: number): number {
  // SSR-safe initial state: only the in-memory cache, so the server and a fresh
  // client load agree. localStorage is read in the effect, client-side only.
  const [count, setCount] = useState<number>(cached.get(repo) ?? fallback)

  useEffect(() => {
    const memo = cached.get(repo)
    if (memo !== undefined) {
      setCount(memo)
      return
    }

    const stored = readStored(repo)
    if (stored) {
      // Paint the cached number immediately either way; only skip the network
      // round-trip while the entry is still fresh.
      cached.set(repo, stored.count)
      setCount(stored.count)
      if (Date.now() - stored.at < TTL_MS) return
    }

    let active = true
    if (!inflight.has(repo)) inflight.set(repo, fetchStarCount(repo))
    inflight.get(repo)!.then((value) => {
      inflight.delete(repo)
      if (value === null) return
      cached.set(repo, value)
      writeStored(repo, value)
      if (active) setCount(value)
    })
    return () => {
      active = false
    }
  }, [repo, fallback])

  return count
}
