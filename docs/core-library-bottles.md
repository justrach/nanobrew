# Core library catalog

The default catalog refresh pairs Apple Silicon Homebrew bottles with the
validated Intel source bottles from
[the Intel library release](https://github.com/justrach/nanobrew/releases/tag/intel-libraries-35003597184-1).
Both architectures use zlib 1.3.2, xz 5.8.4, lz4 1.10.0 and OpenSSL 3.6.4.
The shared ca-certificates pin is 2026-08-13. Matching Linux companion pins
are retained; native execution checks cover macOS only.

The `Core library bottles` workflow mirrors all five packages and all their
platform assets to GitHub Container Registry. Anonymous downloads must match
the pinned checksums. Fresh Apple Silicon (macOS 26) and Intel (macOS 15)
Nanobrew installations must record the exact version and digest, load each
native library in a compiled consumer, round-trip compressed data, and
generate and verify an OpenSSL certificate. Results are saved as artifacts.
The workflow repeats on catalog changes and can be dispatched manually.

Apple Silicon pins use the oldest available reviewed Homebrew bottle for
each version: Sonoma for zlib/lz4/OpenSSL and Sequoia for xz. Consequently,
this xz ARM pin requires macOS 15 or later. These checks do not establish
compatibility with older macOS releases, nor with every downstream package.

After this catalog lands, `nb update-registry` fetches the new default pins.
Use `nb upgrade` for existing installations. A same-version bottle rebuild
may require reinstalling that package to replace already installed bytes;
the validation workflow uses fresh installations for this reason.

For future updates, change both registry files together and retain matching
versions for every platform. Refresh Homebrew metadata/checksums, build and
test any missing Intel source bottle, then let the mirror and native install
jobs finish before merging. Source recipes, licenses and evidence remain
available in the linked release.
