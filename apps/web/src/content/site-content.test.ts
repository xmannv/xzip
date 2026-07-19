import { describe, expect, it } from 'vitest'

import { downloadUrl } from './site-content'

describe('site content contract', () => {
  it('points downloads at the latest GitHub release', () => {
    expect(downloadUrl).toBe('https://github.com/xmannv/xzip/releases/latest')
  })
})
