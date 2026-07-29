<div align="center">
  <img src="apps/macos/XZip/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="XZIP app icon">

# XZIP

**The archive utility macOS deserves.**

A fast, private, native archive utility that makes everyday archive work feel at home on the Mac.

  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-111827?style=flat-square&logo=apple&logoColor=white" alt="macOS 15 or later">
    <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  </p>

[**Download for Mac**](https://github.com/xmannv/xzip/releases/latest) · [Release notes](https://github.com/xmannv/xzip/releases) · [Report an issue](https://github.com/xmannv/xzip/issues/new/choose)
</div>

---

## Why XZIP?

XZIP keeps archive work focused, native, and local. Browse files before extraction, create and open common formats, and use familiar macOS integrations without sending archive contents to a web service.

| Native experience                        | Archive essentials                                             | Private by architecture                                     |
| ---------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------- |
| Finder, Quick Look, and Share extensions | Browse, compress, extract, test, and manage encrypted archives | Local processing with passwords protected by Apple Keychain |

## Highlights

- **Browse before extracting** — inspect archive contents in a native file browser.
- **Work across common formats** — handle ZIP, 7Z, TAR, RAR, DMG, and more through the bundled archive engine.
- **Stay inside macOS** — use Finder actions, Quick Look previews, and the Share extension.
- **Protect encrypted archives** — securely remember passwords with Apple Keychain.
- **Keep files local** — no archive upload service, account, or cloud processing.
- **Receive native updates** — signed releases are delivered through Sparkle and a GitHub-hosted appcast.

## Repository layout

```text
XZIP/
├── apps/
│   ├── macos/        Native Swift app, extensions, XcodeGen project, and XZIPCore
│   └── web/          Product site built with TanStack Start and Tailwind CSS 4
├── Resources/        Repository-level resources used by native development
├── .github/          Release automation and Sparkle appcast generation
├── package.json      Bun workspace and Turborepo commands
└── turbo.json        Monorepo task pipeline
```

The native and web toolchains remain intentionally isolated: XcodeGen and SwiftPM own the macOS project, while Bun and Turborepo own JavaScript tasks.

<details>
<summary><strong>Development setup</strong></summary>

## Requirements

### Entire repository

- [Git](https://git-scm.com/)
- [Bun](https://bun.sh/) 1.3 or later

### macOS app

- macOS 15 or later
- Xcode 16.3 or later with Command Line Tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Install XcodeGen with Homebrew:

```bash
brew install xcodegen
```

## Getting started

Clone the repository and install web dependencies:

```bash
git clone https://github.com/xmannv/xzip.git
cd xzip
bun install --frozen-lockfile
```

`--frozen-lockfile` installs exactly what `bun.lock` records and fails instead of
silently resolving a different version, which is what CI runs too. Use a plain
`bun install` only when you intend to change dependencies.

### Run the product website

```bash
bun run dev
```

Turborepo starts the web workspace at `http://localhost:3000`.

Useful repository-wide checks:

```bash
bun run lint
bun run typecheck
bun run test
bun run build
```

### Generate the macOS project

The Xcode project is generated from `apps/macos/project.yml` and is not the source of truth.

```bash
cd apps/macos
xcodegen generate
open XZip.xcodeproj
```

Fetch the bundled 7-Zip engine before running integration tests or producing a native app build:

```bash
cd apps/macos
bash scripts/fetch_binaries.sh
```

### Test XZIPCore

```bash
swift test --package-path apps/macos/Packages/XZIPCore
```

Tests that require `7zz` are skipped when the binary has not been fetched.

### Build a local Release app

```bash
cd apps/macos
bash scripts/build_local_release.sh
```

The script fetches native binaries, regenerates the Xcode project, builds an ad-hoc-signed app for the current Mac, and writes it to `apps/macos/release/XZip.app`.

</details>

## Release architecture

- **App downloads:** [GitHub Releases](https://github.com/xmannv/xzip/releases)
- **Product website:** Cloudflare Workers
- **Sparkle feed:** [`https://xmannv.github.io/xzip/appcast.xml`](https://xmannv.github.io/xzip/appcast.xml)
- **Appcast automation:** publishing a GitHub Release triggers [the update workflow](.github/workflows/update-appcast.yml), which regenerates `appcast.xml` on the `gh-pages` branch.

Distribution builds require Apple Developer ID signing, notarization credentials, and a Sparkle signing key. These secrets must remain outside the repository. See `apps/macos/scripts/build_release.sh` for the required environment variables and release steps.

## Our products

- [Xermius](https://xermius.com)
- [XKey](https://github.com/xmannv/xkey/)

## License

XZIP's own source code is licensed under the [Apache License 2.0](LICENSE).

Apache-2.0 was chosen over MIT for two reasons that matter once the project takes
outside contributions: it grants patent rights explicitly (§3), and it states that
anything you submit is contributed under the same terms (§5) — so no separate CLA is
needed for basic hygiene.

## Third-party software

The Apache-2.0 license above covers **XZIP's source code only**. It does not extend to
the third-party binaries that ship inside the app bundle, which keep their own licenses:

| Component | License | Notes |
| --- | --- | --- |
| `7zz` (7-Zip 26.02) | GNU LGPL + unRAR terms | Invoked as a subprocess, unmodified, never linked into XZIP |
| Sparkle 2.x | MIT | Auto-update framework |

Because `7zz` is executed as a separate process rather than linked, its copyleft terms do
not extend to XZIP's own source. The unRAR terms additionally forbid using that code to
re-create RAR compression — XZIP only extracts RAR archives and never creates them.

Full notices: [`apps/macos/THIRD_PARTY_LICENSES.md`](apps/macos/THIRD_PARTY_LICENSES.md).
