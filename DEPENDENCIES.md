# Vendored dependencies and notices

Dependencies are copied as tracked files, not Git submodules. The versions
below are declared by their bundled `package.json` files; they are not claims
that the contents match an unmodified upstream tag or a verified commit.
Exact distributed file bytes are recorded in `DEPENDENCIES.sha256`.
The root `.gitattributes` disables Git text conversion for vendored files so
checksums remain valid even on Windows with `core.autocrlf=true`.
Do not replace these copies with floating `forge install` versions.

| Directory | Declared version | Upstream | License notices |
| --- | --- | --- | --- |
| `lib/forge-std` | 1.10.0 | https://github.com/foundry-rs/forge-std | Apache-2.0 OR MIT; bundled license files |
| `lib/openzeppelin-contracts` | 5.4.0 | https://github.com/OpenZeppelin/openzeppelin-contracts | MIT; bundled LICENSE |
| `lib/solady` | 0.1.24 | https://github.com/Vectorized/solady | MIT; bundled LICENSE.txt |
| `lib/v3-core` | 1.0.0 | https://github.com/Uniswap/v3-core | Bundled Business Source License 1.1 with change-license terms; file-level notices also apply |
| `lib/v3-periphery` | 1.3.0 | https://github.com/Uniswap/v3-periphery | GPL-2.0-or-later; bundled LICENSE and file-level notices |

Nested dependency contents and notices are retained with their parent vendored
tree. Embedded `.gitmodules` files are upstream metadata, not instructions to
initialize dependencies in this distribution.

First-party source identifiers include MIT, ISC, GPL-2.0-or-later, and
UNLICENSED. Preserve each file's notice. There is no repository-wide relicensing.
Review applicable terms before redistribution or commercial use.

Checksums identify bytes, not publication permission, authenticity, or the
absence of vulnerabilities. Dependency changes require a new reviewed manifest
and the full public validation matrix.
