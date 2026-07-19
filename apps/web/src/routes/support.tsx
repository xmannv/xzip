import { createFileRoute } from '@tanstack/react-router'
import { DocumentLayout } from '../components/site-shell'

export const Route = createFileRoute('/support')({
  head: () => ({
    meta: [
      { title: 'Support — XZIP' },
      { name: 'description', content: 'Help and answers for XZIP.' },
    ],
  }),
  component: Page,
})

const issuesUrl = 'https://github.com/xmannv/xzip/issues/new/choose'

const faqs: { q: string; a: string }[] = [
  {
    q: 'How do I make XZIP the default app for archives?',
    a: 'Settings › Formats lists every archive type. Click "Set XZIP as default" for all, or toggle types individually. You can also right-click any archive in Finder › Get Info › Open with › Change All.',
  },
  {
    q: 'Can XZIP create RAR files?',
    a: 'No — RAR is a proprietary format, so XZIP extracts RAR (including RAR5 and multi-part) but compresses to ZIP, 7Z, TAR and friends instead. 7Z usually compresses smaller than RAR anyway.',
  },
  {
    q: 'I forgot the password to an archive I made.',
    a: 'If you let XZIP remember it, it is in your macOS Keychain: open Keychain Access and search for the archive name. If not, the password cannot be recovered — AES-256 has no back door, which is the point.',
  },
  {
    q: 'How do I open a .001 / .002 split archive?',
    a: 'Just double-click the .001 file. XZIP finds the remaining parts in the same folder and offers to join them. Missing parts are listed by name so you know what to re-download.',
  },
  {
    q: 'Why does macOS warn me about an app I extracted?',
    a: 'XZIP quarantines apps extracted from archives, so Gatekeeper checks them on first launch — same as a browser download. You can disable this in Settings › Extract, but we recommend leaving it on.',
  },
  {
    q: 'Where do extracted files go?',
    a: 'By default, next to the archive. Change the default in Settings › Extract, pick a destination per-extraction with ⌥⌘E, or drop files onto a Place in the sidebar to extract them there.',
  },
  {
    q: 'Does XZIP have a command-line interface?',
    a: 'Yes — install it from Settings › General › "Install command-line tool", then run `xzip --help` in Terminal. Shortcuts and Automator actions are included too.',
  },
]

function Page() {
  return (
    <DocumentLayout
      title="Support"
      intro="Most answers are below. For anything else, open a GitHub issue or email support@xzip.dev — we usually reply within a day."
    >
      <div className="faq-list">
        {faqs.map((faq) => (
          <div className="faq-card" key={faq.q}>
            <div className="faq-q">{faq.q}</div>
            <div className="faq-a">{faq.a}</div>
          </div>
        ))}
      </div>
      <div className="doc-actions">
        <a
          className="pill primary"
          href={issuesUrl}
          target="_blank"
          rel="noopener noreferrer"
        >
          Open a GitHub issue
        </a>
        <a className="pill ghost" href="mailto:support@xzip.dev">
          Email support
        </a>
      </div>
    </DocumentLayout>
  )
}
