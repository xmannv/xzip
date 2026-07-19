// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  classify,
  normalize,
  readStored,
  type ReleaseNote,
} from './github-releases'

const REPO = 'owner/xzip'
const STORAGE_KEY = `xzip-releases:${REPO}`

describe('classify', () => {
  it('labels the fix/bug family as Fixed', () => {
    expect(classify('Fixed a crash on launch')).toBe('Fixed')
    expect(classify('Bug: window loses focus')).toBe('Fixed')
    expect(classify('Resolve the fix for drag and drop')).toBe('Fixed')
  })
  it('does not mislabel words that merely contain "fix"', () => {
    expect(classify('Prefix handling for split archives')).toBe('New')
    expect(classify('Suffix rules now respected')).toBe('New')
  })
  it('labels leading improve/update verbs as Improved', () => {
    expect(classify('Improved extraction speed')).toBe('Improved')
    expect(classify('Updated the compare table')).toBe('Improved')
  })
  it('falls back to New', () => {
    expect(classify('Added Finder integration')).toBe('New')
  })
})

describe('normalize', () => {
  it('gives LATEST to the newest stable release, not a leading prerelease', () => {
    const notes = normalize([
      { tag_name: 'v2.0.0-beta.1', prerelease: true },
      { tag_name: 'v1.4.0', prerelease: false },
      { tag_name: 'v1.3.0', prerelease: false },
    ])
    expect(notes[0]).toMatchObject({ tag: 'BETA', latest: false })
    expect(notes[1]).toMatchObject({ tag: 'LATEST', latest: true })
    expect(notes[2]).toMatchObject({ tag: 'RELEASE', latest: false })
  })
  it('drops drafts and derives unique stable keys', () => {
    const notes = normalize([
      { tag_name: 'v1.1.0', draft: true },
      { tag_name: 'v1.0.0', name: 'Launch' },
      { name: 'Launch' }, // same display name, no tag
    ])
    expect(notes).toHaveLength(2)
    expect(new Set(notes.map((note) => note.key)).size).toBe(2)
    expect(notes[0].version).toBe('Launch')
  })

  it('honors an explicit **Fixed:** label over the remaining wording', () => {
    const notes = normalize([
      {
        tag_name: 'v1.0.0',
        body: '- **Fixed:** improved retry logic\n- Added dark mode',
      },
    ])
    // The label wins even though "improved …" would otherwise read as Improved,
    // and the label is stripped from the displayed text.
    expect(notes[0].items[0]).toMatchObject({
      kind: 'Fixed',
      text: 'improved retry logic',
    })
    expect(notes[0].items[1]).toMatchObject({ kind: 'New' })
  })
})

describe('readStored', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => localStorage.clear())

  const validNote: ReleaseNote = {
    key: 'v1.0.0',
    version: 'v1.0.0',
    date: 'January 1, 2026',
    tag: 'LATEST',
    latest: true,
    items: [{ kind: 'New', text: 'First release' }],
  }

  it('returns a well-formed cached payload', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ at: Date.now(), releases: [validNote] }),
    )
    const stored = readStored(REPO)
    expect(stored?.releases).toHaveLength(1)
    expect(stored?.releases[0].key).toBe('v1.0.0')
  })

  it('discards a payload whose items are missing required fields', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        at: Date.now(),
        releases: [{ ...validNote, items: [{ kind: 'New' }] }],
      }),
    )
    expect(readStored(REPO)).toBeNull()
  })

  it('discards a payload with the wrong top-level shape', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ releases: [validNote] }))
    expect(readStored(REPO)).toBeNull()
  })
})
