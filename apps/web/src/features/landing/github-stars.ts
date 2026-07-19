import { useEffect, useState } from 'react'

/** GitHub-style compact star count, e.g. 4234 -> "4.2k". */
export function formatStars(count: number): string {
  if (count >= 1000) {
    return `${(count / 1000).toFixed(1).replace(/\.0$/, '')}k`
  }
  return String(count)
}

let cachedCount: number | null = null
let inflight: Promise<number | null> | null = null

async function fetchStarCount(repo: string): Promise<number | null> {
  try {
    const response = await fetch(`https://api.github.com/repos/${repo}`, {
      headers: { Accept: 'application/vnd.github+json' },
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
  const [count, setCount] = useState<number>(cachedCount ?? fallback)

  useEffect(() => {
    if (cachedCount !== null) {
      setCount(cachedCount)
      return
    }
    let active = true
    inflight ??= fetchStarCount(repo)
    inflight.then((value) => {
      inflight = null
      if (value === null) return
      cachedCount = value
      if (active) setCount(value)
    })
    return () => {
      active = false
    }
  }, [repo, fallback])

  return count
}
