# Third-Party Licenses & Notices

XZip bundles the following open-source command-line tools.

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

## Sparkle — v2.x

Auto-update framework, licensed under the **MIT License**.
https://github.com/sparkle-project/Sparkle

---

Full license texts are available at each project's repository linked above.
