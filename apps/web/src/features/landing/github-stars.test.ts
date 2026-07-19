// @vitest-environment jsdom
import { renderHook, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { formatStars } from './github-stars'

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

describe('useGitHubStars', () => {
  // Reset the module-level star cache so each test starts clean.
  beforeEach(() => {
    vi.resetModules()
  })
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
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
})
