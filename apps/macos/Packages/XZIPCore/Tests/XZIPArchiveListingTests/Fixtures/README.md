# Archive listing fixtures

Deterministic fixtures committed for `LibarchiveListingReaderTests`; tests do not generate archives or invoke bundled `7zz`. This document records provenance and does not claim XZip authorship of the fixture contents.

## Generated fixture provenance

- `sample.zip`: generated once with Python standard-library `zipfile` using fixed paths, timestamps, modes, and stored compression; no third-party archive fixture was copied.
- `sample.tar`: generated once with Python standard-library `tarfile` using USTAR and fixed paths, timestamps, and modes; no third-party archive fixture was copied.
- `oversized-pax-ids.tar`: generated once with Python standard-library `tarfile` using PAX format, fixed path/content/timestamp/mode, UID `4294967296`, and GID `1099511627776`; SHA-256 `672c9b9ea38906e4cc22641f8cb8cb2486b7fc1edc73bec4807ecc7e2730e565`; no third-party archive fixture was copied.
- `legacy-v7.tar`: generated once as a checksum-valid V7 TAR with no `ustar` marker, fixed path/content/timestamp/mode; SHA-256 `8e155ee9ed0bb1798d560b2edc72d14314a79bc51fa44ec45c66a361784991e0`; no third-party archive fixture was copied.
- `lzip-ustar-collision.tar`: generated once with a valid LZIP header plus checksum-valid TAR-shaped fields and a false `ustar` marker at offset 257; SHA-256 `6e077d64f3ec7384455e54ac75f9fb5b31c2b6ab43f319e49e5a9f375116ba23`; no third-party archive fixture was copied.
- `corrupt.zip`: derived as the first 12 bytes of the committed `sample.zip`.

## Upstream libarchive test-corpus provenance

The following files were decoded from the listed uuencoded source paths at upstream libarchive tag `v3.8.9` and are otherwise unmodified:

- `sample.7z`: [`libarchive/test/test_read_format_7zip_copy.7z.uu`](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_7zip_copy.7z.uu)
- `sample-rar4.rar`: [`libarchive/test/test_read_format_rar.rar.uu`](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_rar.rar.uu)
- `sample-rar5.rar`: [`libarchive/test/test_read_format_rar5_multiple_files.rar.uu`](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_rar5_multiple_files.rar.uu)
- `header-encrypted.7z`: [`libarchive/test/test_read_format_7zip_encryption_header.7z.uu`](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_7zip_encryption_header.7z.uu); password: `12345678`.
- `empty.7z`: [`libarchive/test/test_read_format_7zip_empty_archive.7z.uu`](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_7zip_empty_archive.7z.uu)
- `disguised-ar.zip`: [`libarchive/test/test_read_format_ar.ar.uu`](https://github.com/libarchive/libarchive/blob/v3.8.9/libarchive/test/test_read_format_ar.ar.uu), renamed after decoding to verify unsupported formats cannot pass the ZIP extension gate.

These copied fixtures follow the notices governing the upstream libarchive `v3.8.9` test corpus. The authoritative licensing source is upstream [`COPYING`](https://github.com/libarchive/libarchive/blob/v3.8.9/COPYING), together with any controlling file-specific notice in the listed source file. The RAR fixtures are used only for read/list tests; this test suite does not create RAR archives.
