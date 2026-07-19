export type ArchiveRow = {
  ext: string
  icon: string
  name: string
  size: string
  kind: string
  selected?: boolean
}
export type ShowcaseSlide = {
  label: string
  tag: string
  title: string
  body: string
  note: string
}
export type FeatureCard = { num: string; title: string; body: string }
export type ComparisonRow = {
  row: string
  xzip: string
  builtIn: string
  betterZip: string
  winZip: string
  keka: string
}

export const archiveRows: ArchiveRow[] = [
  { ext: 'DIR', icon: '#0A84FF', name: 'Designs', size: '—', kind: 'Folder' },
  {
    ext: 'PNG',
    icon: '#30d158',
    name: 'app-icon.png',
    size: '1.2 MB',
    kind: 'PNG image',
  },
  {
    ext: 'PDF',
    icon: '#ff453a',
    name: 'brand-guide.pdf',
    size: '8.4 MB',
    kind: 'PDF document',
    selected: true,
  },
  {
    ext: 'SK',
    icon: '#ff9f0a',
    name: 'mockup-final.sketch',
    size: '24.6 MB',
    kind: 'Sketch file',
  },
]

export const showcaseSlides: ShowcaseSlide[] = [
  {
    label: 'Browse',
    tag: 'BROWSE',
    title: "Open it. Don't unpack it.",
    body: 'A Finder-familiar list of everything inside the archive, including subfolders. Search finds a file in a 10 GB backup in milliseconds. Drag a row out to extract just that file.',
    note: 'Space = Quick Look · ⌘F = Search · ⌘E = Extract',
  },
  {
    label: 'Drop',
    tag: 'DROP ZONE',
    title: 'Two targets. Zero manuals.',
    body: 'The empty window tells you exactly what it does: drop files on the left to compress, archives on the right to extract. The Dock icon takes drops too.',
    note: 'Default format switchable right at the zone',
  },
  {
    label: 'Compress',
    tag: 'COMPRESS',
    title: 'Every option. One sheet.',
    body: 'Pick a format, drag the level slider and watch the size estimate update live. One toggle for AES-256 with Safari-style password suggestions. Split into volumes if it has to fit somewhere.',
    note: 'Estimate sampled in real time — no surprises',
  },
  {
    label: 'Queue',
    tag: 'QUEUE',
    title: 'Work in parallel.',
    body: 'Compress, extract, and test at the same time. A conflict or wrong password pauses one item — never the whole queue. A system notification tells you when everything is done.',
    note: 'Pause / retry per task · transcript on error',
  },
  {
    label: 'Finder',
    tag: 'FINDER',
    title: 'Never leave Finder.',
    body: 'Compress, extract, and run your saved presets straight from the right-click menu. For most days, you never open XZIP at all.',
    note: 'Presets sync to the context menu automatically',
  },
]

export const formatGroups = {
  both: [
    'ZIP',
    '7Z',
    'TAR',
    'GZ',
    'BZ2',
    'XZ',
    'ZSTD',
    'TZST',
    'DMG',
    'TGZ',
    'TBZ',
    'TXZ',
  ],
  extractOnly: [
    'RAR',
    'ISO',
    'CAB',
    'DEB',
    'RPM',
    'EPUB',
    'JAR',
    'CPIO',
    'LZH',
    'WIM',
    'CHM',
    'ARJ',
    'XIP',
    'PAX',
    'CBZ',
    'Z',
    'LZMA',
    'UDF',
    'SQUASHFS',
  ],
} as const

export const featureCards: FeatureCard[] = [
  {
    num: '⌘1',
    title: 'One-key extraction',
    body: 'Pin folders as Places. Press ⌘1 and the archive lands in Downloads — or drop files straight onto a Place in the sidebar.',
  },
  {
    num: '∥',
    title: 'A queue that never blocks',
    body: 'Compress, extract, and test in parallel. A file conflict pauses one item, not your afternoon.',
  },
  {
    num: '␣',
    title: 'Space to preview',
    body: 'Quick Look PDFs, images, and video inside the archive — streamed, never written to disk.',
  },
  {
    num: '.001',
    title: 'Big files, small pieces',
    body: 'Split archives to fit any upload limit. Open a .001 and XZIP finds the rest of the set automatically.',
  },
  {
    num: '✎',
    title: 'Edit & save back',
    body: 'Open an archived file in any app. Hit save, and the archive updates itself. No unpack–repack dance.',
  },
  {
    num: '⌃',
    title: 'Right there in Finder',
    body: 'Compress, extract, and run your presets from the right-click menu — without launching XZIP at all.',
  },
]

export const comparisonRows: ComparisonRow[] = [
  {
    row: 'Browse archives without extracting',
    xzip: '✓',
    builtIn: '—',
    betterZip: '✓',
    winZip: '✓',
    keka: '—',
  },
  {
    row: '30+ formats incl. RAR, DMG, ISO',
    xzip: '✓',
    builtIn: 'ZIP only',
    betterZip: '✓',
    winZip: 'No DMG/ISO',
    keka: '✓',
  },
  {
    row: 'AES-256 password protection',
    xzip: '✓',
    builtIn: '—',
    betterZip: '✓',
    winZip: '✓',
    keka: '✓',
  },
  {
    row: 'Split archives & auto-join .001 parts',
    xzip: '✓',
    builtIn: '—',
    betterZip: '✓',
    winZip: '—',
    keka: '✓',
  },
  {
    row: 'Edit files inside an archive',
    xzip: '✓',
    builtIn: '—',
    betterZip: '✓',
    winZip: 'Partial',
    keka: '—',
  },
  {
    row: 'Built for macOS only',
    xzip: '✓',
    builtIn: '✓',
    betterZip: '✓',
    winZip: '—',
    keka: '✓',
  },
  {
    row: 'Price',
    xzip: 'Free',
    builtIn: 'Free',
    betterZip: '$24.95',
    winZip: '$38.45/yr',
    keka: 'Free',
  },
]
