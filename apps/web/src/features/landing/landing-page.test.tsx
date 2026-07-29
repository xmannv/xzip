// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRouter,
} from '@tanstack/react-router'
import { LandingPage } from './landing-page'

// LandingPage renders router <Link>s, so it needs a router context. A minimal
// memory router whose root route renders the page provides that in tests.
async function renderLandingPage() {
  const rootRoute = createRootRoute({ component: () => <LandingPage /> })
  const router = createRouter({
    routeTree: rootRoute,
    history: createMemoryHistory({ initialEntries: ['/'] }),
  })
  await act(async () => {
    await router.load()
  })
  return render(<RouterProvider router={router} />)
}

describe('XZIP landing v3', () => {
  beforeEach(() => {
    localStorage.clear()
    vi.useFakeTimers()
  })
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('renders the source hero and complete sections', async () => {
    await renderLandingPage()
    const heading = screen.getByRole('heading', { level: 1 })
    expect(heading.textContent).toBe('The archive utilitymacOS deserves.')
    expect(
      screen.getByRole('heading', {
        name: "Five screens. That's the whole app.",
      }),
    ).toBeTruthy()
    expect(
      screen.getByRole('heading', { name: 'Reads 30+ formats. Writes 12.' }),
    ).toBeTruthy()
    expect(
      screen.getByRole('heading', { name: 'Honest security.' }),
    ).toBeTruthy()
    expect(
      screen.getByRole('heading', { name: 'How XZIP compares.' }),
    ).toBeTruthy()
  })

  it('navigates showcase and stops autoplay after manual input', async () => {
    await renderLandingPage()
    expect(screen.getByText("Open it. Don't unpack it.")).toBeTruthy()
    fireEvent.click(screen.getByRole('tab', { name: 'Queue' }))
    expect(screen.getByText('Work in parallel.')).toBeTruthy()
    act(() => vi.advanceTimersByTime(6000))
    expect(screen.getByText('Work in parallel.')).toBeTruthy()
  })

  it.each([
    ['reduced motion', true, 'auto'],
    ['standard motion', false, 'smooth'],
  ])('centers showcase tabs with %s behavior', async (_, reduced, behavior) => {
    vi.stubGlobal('matchMedia', (query: string) => ({
      matches:
        query === '(prefers-reduced-motion: reduce)' ? reduced : !reduced,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    }))
    await renderLandingPage()
    const tablist = screen.getByRole('tablist')
    const scrollBy = vi.fn()
    Object.defineProperty(tablist, 'scrollBy', {
      configurable: true,
      value: scrollBy,
    })

    fireEvent.click(screen.getByRole('tab', { name: 'Queue' }))

    expect(scrollBy).toHaveBeenLastCalledWith(
      expect.objectContaining({ behavior }),
    )
  })

  it('autoplays and restores a valid saved theme', async () => {
    localStorage.setItem('xzip-theme', 'dark')
    await renderLandingPage()
    expect(document.documentElement.dataset.theme).toBe('dark')
    act(() => vi.advanceTimersByTime(6000))
    expect(screen.getByText('Two targets. Zero manuals.')).toBeTruthy()
  })

  it('cycles system → light → dark and persists', async () => {
    await renderLandingPage()
    // No stored preference: starts on system (resolved light in jsdom).
    fireEvent.click(
      screen.getByRole('button', { name: 'Switch to light theme' }),
    )
    expect(localStorage.getItem('xzip-theme')).toBe('light')
    expect(document.documentElement.dataset.theme).toBe('light')
    fireEvent.click(
      screen.getByRole('button', { name: 'Switch to dark theme' }),
    )
    expect(localStorage.getItem('xzip-theme')).toBe('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')
  })

  it('follows the system theme by default', async () => {
    let listener: ((event: { matches: boolean }) => void) | null = null
    const media = {
      matches: true,
      addEventListener: (
        _: string,
        cb: (event: { matches: boolean }) => void,
      ) => {
        listener = cb
      },
      removeEventListener: () => {
        listener = null
      },
    }
    vi.stubGlobal('matchMedia', () => media)
    await renderLandingPage()
    expect(document.documentElement.dataset.theme).toBe('dark')
    act(() => {
      media.matches = false
      listener?.({ matches: false })
    })
    expect(document.documentElement.dataset.theme).toBe('light')
  })
})
