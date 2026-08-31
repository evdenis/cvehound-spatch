# cvehound-spatch

A prebuilt [Coccinelle](https://coccinelle.gitlabpages.inria.fr/website/)
`spatch`, packaged as a Python wheel so that
[CVEhound](https://github.com/evdenis/cvehound) works without asking you to
install OCaml.

**You probably do not want this package on its own.** Install it through
CVEhound, which picks it up automatically:

```shell
pip install 'cvehound[spatch]'
```

CVEhound still runs happily against a system `spatch`; this package only removes
the need for one. Resolution order is `--spatch` / config → `$CVEHOUND_SPATCH` →
this package → `PATH`.

## What is in the wheel

Four files inside the `cvehound_spatch/` package directory, 20-25 MB:

| file | |
| --- | --- |
| `spatch` | the stripped native binary |
| `standard.iso` | coccinelle's isomorphism file |
| `standard.h` | coccinelle's builtin macro definitions |
| `BUILD-INFO` | provenance: coccinelle commit, OCaml version, configure flags |

They sit next to each other on purpose: spatch locates its data files relative
to the real path of its own executable, so the directory is relocatable and
callers need no `--iso-file`/`--macro-file-builtins` arguments.

Wheels are built for Linux `x86_64` and `aarch64` against glibc 2.28
(`manylinux_2_28`), and for macOS `arm64` against a macOS 11 deployment target
(`macosx_11_0_arm64`). The binary links against nothing but the platform's own
libc — glibc on Linux, `libSystem` on macOS. On any other platform the wheel
simply does not install, and CVEhound falls back to `PATH`. Installing needs pip
20.3 or newer, which is where `manylinux_2_28` support landed.

One runtime requirement is not in the wheel: **`diff`** (diffutils). Coccinelle
renders what a rule matched by shelling out to it, and on a system without it
spatch prints an internal error and still exits 0 — a match becomes silence.
Every distribution has it; minimal container images sometimes do not.

## Using it directly

```python
import cvehound_spatch

cvehound_spatch.spatch_path()      # PosixPath('.../cvehound_spatch/spatch')
cvehound_spatch.COCCINELLE_VERSION # '1.3.2'
cvehound_spatch.COCCINELLE_COMMIT  # the exact commit it was built from
```

```shell
python -m cvehound_spatch --path         # where the binary is
python -m cvehound_spatch --build-info   # what it was built from
python -m cvehound_spatch --version      # anything else is passed to spatch
```

## Choices made

This is not a general-purpose coccinelle build. It is the smallest, fastest
build that runs CVEhound's rules, and every deviation from upstream defaults was
decided by measurement:

- **No Python scripting** (`--disable-python`). Coccinelle's Python support
  `dlopen`s libpython by heuristic search, which fails on interpreters that ship
  no shared libpython — a whole class of "works on my machine". CVEhound's rules
  report by starring lines (`*` context mode) and need no scripting at all, so
  the support is dead weight; dropping it also cuts per-invocation startup from
  ~50 ms to ~9 ms, which matters when a scan runs 500+ invocations. A rule that
  did use `script:python` fails loudly here (exit 255), never silently.
- **No OCaml scripting** (`--disable-ocaml`). Runtime `script:ocaml` compilation
  would require an OCaml toolchain on the user's machine — the opposite of the
  point of this package.
- **No PCRE syntax** (`--disable-pcre-syntax`). No rule uses `=~`; the `Str`
  fallback stays available.
- **OCaml 5.3**. The 5.x runtime is 20-25 % faster than 4.x on the heavy rules,
  by far the largest effect found. Verdicts are identical, and coccinelle's own
  test suite scores the same on both.
- **OCaml built `--without-zstd`** (`ocaml-option-no-compression`). From 5.1 the
  runtime links libzstd wherever configure finds it, and a wheel cannot ship a
  Homebrew dylib — on macOS this put `/opt/homebrew/opt/zstd` straight into
  `otool -L`. The manylinux image happens to carry no zstd headers, so the Linux
  build was getting the same result by luck; asking for it makes the invariant
  explicit on both. Nothing is given up: compressed marshalling is opt-in, and
  the compilation artifacts zstd would shrink are not shipped.
- **flambda `-O3`, but no BOLT.** Both were built and measured twice. The first
  study (six heavy rules, OCaml 4.14, one spatch exec per rule) put flambda at
  2-3 % and rejected it. Re-measured on the real corpus — 490 rules, each
  compared against itself, both binary orders — flambda is worth **4.5 %** of
  CPU, and 5.3 % when spatch is run as a fork-per-request server. The earlier
  number was an artifact of a workload whose cost sat in a few heavy rules;
  inlining pays across the many small and medium ones. It costs +11.4 MB, which
  buys +428 minor page faults per exec and 0.05 ms — a real cost, and a
  negligible one.

  BOLT is worth a further ~1.3 points and is **not** shipped. It needs a
  representative workload to train a profile on — a kernel tree and the rule
  corpus — which this build does not have and would have to grow, and its
  benefit measures at zero once spatch shares parsed ASTs between rules, which
  is the direction CVEhound is heading. The pipeline works and the numbers are
  real (L1i misses −17 %, ITLB −11 %, cycles only −0.7 % because the workload
  is not frontend-bound), so it is written down rather than built in; if that
  ever changes it is there to collect.
  (OCaml has neither LTO nor usable PGO, so there is nothing else to try.)
- **Bounds checks kept.** Coccinelle builds with `-unsafe` by default; removing
  the checks is worth about 1 % here, which is not a good trade against running
  a parser over untrusted sources.
- **Patches on top of 1.3.2.** Two are performance regressions, both submitted
  upstream and carried here until they are in a release:
  - caching of `satLabel` results, which fixes a large regression on rules that
    wrap a pattern in a function context (35× on the rules that trigger it) —
    [coccinelle#417](https://github.com/coccinelle/coccinelle/pull/417),
    reviewed;
  - an atoms-only fallback when the file prefilter's CNF conversion hits
    `max_cnf`. Giving up there returned "no query", which `worth_trying` reads
    as "try every file", so the semantic patch ran over the whole tree with no
    prefiltering at all; it now degrades to a one-clause query over the atoms,
    which is still sound because the formula is negation-free —
    [coccinelle#420](https://github.com/coccinelle/coccinelle/pull/420).

  Four more change how spatch can be driven. The first three are the named
  capabilities this build's `FEATURES` advertises; the fourth is invisible to
  callers and needs no flag:
  - **`--zygote`**, a fork-per-request server mode. It warms `standard.iso` and
    `standard.h` once and then forks per request, so a scan of many rules pays
    process startup once instead of per rule. Every request still runs in its
    own process, so no engine global survives from one rule to the next.
  - **exit 124 on an engine timeout.** A fired `--timeout` used to escape as an
    uncaught `Common.Timeout`, i.e. exit 2, indistinguishable from a crash; it
    now exits 124 the way `timeout(1)` does, keeping the exception name in the
    message for callers that already scrape it.
  - **A shareable AST cache.** `--cache-prefix` entries are written through a
    temporary name and renamed, value before dependencies, so parallel scans
    sharing one cache cannot read a torn entry; `standard.h` is now part of the
    cache key.
  - **Cheaper per-file overhead**: the `standard.iso` parse and `standard.h`
    extraction are memoised, and the cache path no longer forks `/bin/sh` to
    run `mkdir -p` once per file — which a cache *hit* was also paying.

## Provenance and reproducing a build

Sources come from the [`cvehound`
branch](https://github.com/evdenis/coccinelle/tree/cvehound) of the coccinelle
fork — coccinelle 1.3.2 plus the patches above, nothing else. Every wheel
records the exact commit in `BUILD-INFO` and in `COCCINELLE_COMMIT`, and the
capabilities it was *probed* to have in `FEATURES`:

```python
>>> import cvehound_spatch
>>> cvehound_spatch.FEATURES
frozenset({'exit124', 'shared-cache', 'zygote'})
```

`FEATURES` exists because these capabilities cannot be detected from outside:
`--zygote` is dispatched before spatch parses its arguments, so it appears in
no `--help` output, and the version banner is identical with and without it.
`make_wheel.py` probes the binary at pack time rather than asserting, so a
build from a ref that predates a feature advertises nothing instead of lying,
and a consumer reading `getattr(cvehound_spatch, 'FEATURES', frozenset())`
degrades correctly against any older wheel.

To rebuild locally on Linux (needs podman or docker):

```shell
./build-in-container.sh          # -> dist/bundle-<arch>/
./make_wheel.py --bundle dist/bundle-$(uname -m)
```

On macOS there is no container to be portable against, so `build.sh` runs
directly on the host and installs what it needs through Homebrew:

```shell
./build.sh                       # -> dist/bundle-<arch>/
./make_wheel.py --bundle dist/bundle-$(uname -m)
```

`build.sh` is the build on both — inside the `manylinux_2_28` image on Linux, on
the host on macOS — and it fails the build if the binary picks up a dependency
beyond the platform's libc or turns out to have Python support. On Linux it also
rejects a binary needing glibc newer than 2.28; on macOS it rejects one whose
`LC_BUILD_VERSION` disagrees with the deployment target the wheel tag promises,
or whose ad-hoc signature is not valid.

Verify a built wheel with `python tests/smoke.py` after installing it — the same
script CI runs, including a parse check over every CVEhound rule.

## Versioning

The package version is the coccinelle version it contains: `1.3.2`. Packaging
changes and rebuilds that keep the same coccinelle release bump a post-release
segment (`1.3.2.post1`), and a new coccinelle release gives a new version.

## License

The wheel ships coccinelle's binary, so it is distributed under the **GPL-2.0**
(see `LICENSE`), the same license as coccinelle itself. The packaging scripts in
this repository are under the same terms. CVEhound itself is GPL-3.0 and simply
executes this binary as a separate program.
