# Third-Party Licenses & Notices

XZip bundles or uses the following open-source software.

## 7-Zip (7zz) — v26.02

XZip bundles the official 7-Zip console binary (`7zz`) for macOS from
https://www.7-zip.org / https://github.com/ip7z/7zip

7-Zip is licensed under the **GNU LGPL** with additional terms. The relevant
portion for redistribution:

- The 7-Zip source code is available at https://www.7-zip.org/download.html
- The bundled binary is unmodified.

### unRAR restriction (IMPORTANT)

7-Zip's RAR decompression uses code derived from the **unRAR** license. Per that
license:

> The unRAR sources may be used in any software to handle RAR archives without
> limitations free of charge, but cannot be used to develop RAR (WinRAR)
> compatible archiver and to re-create RAR compression algorithm, which is
> proprietary. Distribution of modified unRAR sources in separate form or as a
> part of other software is permitted, provided that the full text of this
> paragraph ... is included.

**XZip only *extracts* RAR archives; it never creates them.** This complies with
the unRAR license. XZip is distributed free of charge.

## libarchive / swift-archive — v3.8.9

XZip uses the Swift Package fork at https://github.com/marcprux/swift-archive,
pinned to package version `3.8.9` (revision
`48fddd77a1d8301ce04e0d7c093fcf0867fa1ff8`), and the upstream libarchive
project is at https://github.com/libarchive/libarchive. The fork provides an
additive SwiftPM wrapper around its included libarchive C source; XZip builds
that source and uses it in-process for archive listing. The package version is
not the embedded C library version: the resolved source identifies its
libarchive tree as `3.9.0dev`.

The libarchive distribution as a whole is Copyright by Tim Kientzle. The
primary BSD 2-Clause notice from the resolved package's authoritative
`COPYING` file is reproduced below:

```text
Copyright (c) 2003-2018 <author(s)>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer
   in this position and unchanged.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR(S) ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
IN NO EVENT SHALL THE AUTHOR(S) BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

The upstream `COPYING` summary also identifies file-specific notices and
exceptions; the actual statements in individual files are controlling:

- `libarchive/archive_read_support_filter_compress.c`,
  `libarchive/archive_write_add_filter_compress.c`, and `libarchive/mtree.5`
  are also subject in whole or in part to a 3-clause UC Regents copyright.
- `libarchive/archive_parse_date.c` is in the public domain.
- `libarchive/archive_blake2.h`, `libarchive/archive_blake2_impl.h`,
  `libarchive/archive_blake2s_ref.c`, and
  `libarchive/archive_blake2sp_ref.c` are triple-licensed with a choice of
  CC0 1.0 Universal, OpenSSL, or Apache 2.0.
- Build files have varying licensing terms and must be checked individually
  before distribution.

The authoritative full notice for the source XZip resolves is the fork's
[`COPYING` at revision `48fddd77a1d8301ce04e0d7c093fcf0867fa1ff8`](https://github.com/marcprux/swift-archive/blob/48fddd77a1d8301ce04e0d7c093fcf0867fa1ff8/COPYING),
together with any controlling notice in an individual source file. Its primary
notice matches upstream libarchive [`COPYING` at tag `v3.8.9`](https://github.com/libarchive/libarchive/blob/v3.8.9/COPYING).

XZip uses libarchive RAR support only to read/list RAR archives. XZip does not
create RAR archives or implement RAR compression.

## Sparkle — v2.x

Auto-update framework, licensed under the **MIT License**.
https://github.com/sparkle-project/Sparkle

---

Full license texts are available at each project's repository linked above.
