import { createFileRoute } from '@tanstack/react-router'
import { DocumentLayout } from '../components/site-shell'
import { GITHUB_REPO } from '../features/landing/landing-chrome'
import { useGitHubReleases } from '../features/landing/github-releases'

export const Route = createFileRoute('/release-notes')({
  head: () => ({
    meta: [
      { title: 'Release notes — XZIP' },
      { name: 'description', content: 'What is new in XZIP.' },
    ],
  }),
  component: Page,
})

const releasesUrl = `https://github.com/${GITHUB_REPO}/releases`

function Page() {
  const { status, releases } = useGitHubReleases(GITHUB_REPO)
  return (
    <DocumentLayout title="Release notes" intro="Every change, in plain language.">
      {status === 'loading'
        ? [0, 1, 2].map((i) => (
            <article className="release-row skeleton" key={i} aria-hidden="true">
              <div className="release-meta">
                <span className="skeleton-bar w-60" />
                <span className="skeleton-bar w-40" />
                <span className="skeleton-pill" />
              </div>
              <div className="release-items">
                <span className="skeleton-bar" />
                <span className="skeleton-bar w-90" />
                <span className="skeleton-bar w-80" />
              </div>
            </article>
          ))
        : null}

      {status === 'error' ? (
        <p className="doc-note">
          Couldn’t reach GitHub right now. View every release directly on{' '}
          <a href={releasesUrl} target="_blank" rel="noopener noreferrer">
            the releases page
          </a>
          .
        </p>
      ) : null}

      {status === 'empty' ? (
        <p className="doc-note">
          No public releases yet. Watch the{' '}
          <a href={releasesUrl} target="_blank" rel="noopener noreferrer">
            releases page
          </a>{' '}
          to be notified when the first build ships.
        </p>
      ) : null}

      {status === 'ready'
        ? releases.map((release) => (
            <article className="release-row" key={release.key}>
              <div className="release-meta">
                <span className="release-version">{release.version}</span>
                {release.date ? (
                  <span className="release-date">{release.date}</span>
                ) : null}
                <span
                  className={`release-tag ${release.latest ? 'latest' : ''}`}
                >
                  {release.tag}
                </span>
              </div>
              <div className="release-items">
                {release.items.length ? (
                  release.items.map((item, index) => (
                    <div className="release-item" key={index}>
                      <span
                        className={`release-kind kind-${item.kind.toLowerCase()}`}
                      >
                        {item.kind}
                      </span>
                      <span>{item.text}</span>
                    </div>
                  ))
                ) : (
                  <p className="doc-note">
                    See the full notes on{' '}
                    <a
                      href={releasesUrl}
                      target="_blank"
                      rel="noopener noreferrer"
                    >
                      GitHub
                    </a>
                    .
                  </p>
                )}
              </div>
            </article>
          ))
        : null}
    </DocumentLayout>
  )
}
