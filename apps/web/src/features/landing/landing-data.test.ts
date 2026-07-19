import { describe, expect, it } from 'vitest'
import {
  archiveRows,
  comparisonRows,
  featureCards,
  formatGroups,
  showcaseSlides,
} from './landing-data'

describe('landing v3 data', () => {
  it('ports every collection from the source design', () => {
    expect(archiveRows).toHaveLength(4)
    expect(showcaseSlides).toHaveLength(5)
    expect(formatGroups.both).toHaveLength(12)
    expect(formatGroups.extractOnly).toHaveLength(19)
    expect(featureCards).toHaveLength(6)
    expect(comparisonRows).toHaveLength(7)
  })

  it('preserves the defining source content', () => {
    expect(showcaseSlides.map((slide) => slide.label)).toEqual([
      'Browse',
      'Drop',
      'Compress',
      'Queue',
      'Finder',
    ])
    expect(formatGroups.both).toContain('DMG')
    expect(formatGroups.extractOnly).toContain('RAR')
    expect(comparisonRows.at(-1)?.row).toBe('Price')
  })
})
