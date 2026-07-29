// @vitest-environment jsdom
import { renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { formatStars, readStored } from './github-stars'

describe('formatStars', () => {
  it('formats thousands with a compact k suffix', () => {
    expect(formatStars(4234)).toBe('4.2k')
    expect(formatStars(4000)).toBe('4k')
    expect(formatStars(12500)).toBe('12.5k')
  })
  it('leaves counts under 1000 untouched', () => {
    expect(formatStars(0)).toBe('0')
    expect(formatStars(999)).toBe('999')
  })
})

describe('readStored', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => localStorage.clear())

  it('returns a well-formed cached payload', () => {
    localStorage.setItem(
      'xzip-stars:owner/repo',
      JSON.stringify({ at: 1234, count: 99 }),
    )
    expect(readStored('owner/repo')).toEqual({ at: 1234, count: 99 })
  })

  it('discards a payload with a missing or non-numeric field', () => {
    localStorage.setItem('xzip-stars:a/b', JSON.stringify({ at: 1234 }))
    expect(readStored('a/b')).toBeNull()
    localStorage.setItem(
      'xzip-stars:c/d',
      JSON.stringify({ at: 1234, count: '99' }),
    )
    expect(readStored('c/d')).toBeNull()
  })

  it('returns null for unparseable JSON', () => {
    localStorage.setItem('xzip-stars:e/f', 'not json')
    expect(readStored('e/f')).toBeNull()
  })
})

describe('useGitHubStars', () => {
  // Reset the module-level star cache so each test starts clean.
  beforeEach(() => {
    vi.resetModules()
    localStorage.clear()
  })
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    localStorage.clear()
  })

  it('returns the fallback then the live count', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ stargazers_count: 5321 }),
      }),
    )
    const { useGitHubStars } = await import('./github-stars')
    const { result } = renderHook(() => useGitHubStars('owner/repo', 4200))
    expect(result.current).toBe(4200)
    await waitFor(() => expect(result.current).toBe(5321))
  })

  it('keeps the fallback when the request fails', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false }))
    const { useGitHubStars } = await import('./github-stars')
    const { result } = renderHook(() => useGitHubStars('owner/other', 4200))
    await waitFor(() => expect(result.current).toBe(4200))
  })

  it('aborts the request via a timeout signal', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ stargazers_count: 10 }),
    })
    vi.stubGlobal('fetch', fetchMock)
    const { useGitHubStars } = await import('./github-stars')
    renderHook(() => useGitHubStars('owner/timeout', 1))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    // A stalled connection must not keep the shared promise pending forever.
    expect(fetchMock.mock.calls[0][1].signal).toBeInstanceOf(AbortSignal)
  })

  it('uses a fresh cached count without hitting the network', async () => {
    localStorage.setItem(
      'xzip-stars:owner/cached',
      JSON.stringify({ at: Date.now(), count: 777 }),
    )
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    const { useGitHubStars } = await import('./github-stars')
    const { result } = renderHook(() => useGitHubStars('owner/cached', 4200))
    await waitFor(() => expect(result.current).toBe(777))
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('revalidates an expired cache while showing the stale count', async () => {
    localStorage.setItem(
      'xzip-stars:owner/stale',
      JSON.stringify({ at: Date.now() - 60 * 60 * 1000, count: 500 }),
    )
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ stargazers_count: 600 }),
      }),
    )
    const { useGitHubStars } = await import('./github-stars')
    const { result } = renderHook(() => useGitHubStars('owner/stale', 4200))
    await waitFor(() => expect(result.current).toBe(600))
  })

  it('does not share a cached count between repositories', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockImplementation((url: string) => ({
        ok: true,
        json: async () => ({
          stargazers_count: url.endsWith('one/one') ? 11 : 22,
        }),
      })),
    )
    const { useGitHubStars } = await import('./github-stars')
    const first = renderHook(() => useGitHubStars('one/one', 0))
    await waitFor(() => expect(first.result.current).toBe(11))
    const second = renderHook(() => useGitHubStars('two/two', 0))
    await waitFor(() => expect(second.result.current).toBe(22))
  })
})
