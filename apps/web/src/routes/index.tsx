import { createFileRoute } from '@tanstack/react-router'
import { LandingPage } from '../features/landing/landing-page'

export const Route = createFileRoute('/')({
  head: () => ({
    meta: [
      { title: 'XZIP — The archive utility macOS deserves' },
      {
        name: 'description',
        content:
          'XZIP is the archive utility macOS deserves — fast, private, and native.',
      },
    ],
  }),
  component: LandingPage,
})
