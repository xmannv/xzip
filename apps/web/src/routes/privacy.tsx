import { createFileRoute } from '@tanstack/react-router'
import { DocumentLayout } from '../components/site-shell'

export const Route = createFileRoute('/privacy')({
  head: () => ({
    meta: [
      { title: 'Privacy — XZIP' },
      {
        name: 'description',
        content: 'How XZIP protects your files and privacy.',
      },
    ],
  }),
  component: Page,
})

function Page() {
  return (
    <DocumentLayout title="Privacy" intro="Last updated July 16, 2026">
      <p>
        <strong>The short version: XZIP collects nothing.</strong> There is no
        account, no cloud, no analytics SDK, and no network connection required
        to use the app.
      </p>
      <h2>Your files</h2>
      <p>
        Everything XZIP does — compressing, extracting, browsing, previewing —
        happens locally on your Mac. Your files never leave your machine through
        XZIP.
      </p>
      <h2>Your passwords</h2>
      <p>
        Archive passwords you choose to remember are stored in the macOS
        Keychain, encrypted by the system and readable only on your Mac. We
        never see them — there is no server for them to be sent to.
      </p>
      <h2>Crash reports</h2>
      <p>
        If XZIP crashes, macOS may offer to send Apple a crash report under your
        system settings. XZIP itself ships no crash-reporting or analytics
        framework. If we ever add opt-in diagnostics, it will be off by default
        and clearly labeled.
      </p>
      <h2>Updates</h2>
      <p>
        The updater contacts our release server only to check the latest version
        number. That request carries no identifier beyond what any HTTP request
        includes, and nothing is logged beyond standard, short-lived server logs.
      </p>
      <h2>Questions</h2>
      <p>
        Open an issue on GitHub or email{' '}
        <a href="mailto:privacy@xzip.dev">privacy@xzip.dev</a>. This policy can
        only get shorter.
      </p>
    </DocumentLayout>
  )
}
