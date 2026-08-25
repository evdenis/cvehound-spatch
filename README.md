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

Four files inside the `cvehound_spatch/` package directory, about 20 MB:

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
(`manylinux_2_28`); the binary links against nothing but glibc. On any other
platform the wheel simply does not install, and CVEhound falls back to `PATH`.
Installing needs pip 20.3 or newer, which is where `manylinux_2_28` support
landed.

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
- **No flambda, no BOLT.** Both were built and measured: 2-3 %, for 6-12 MB of
  extra binary and a much more complicated release pipeline. Not worth it.
  (OCaml has neither LTO nor usable PGO, so there is nothing else to try.)
- **Bounds checks kept.** Coccinelle builds with `-unsafe` by default; removing
  the checks is worth about 1 % here, which is not a good trade against running
  a parser over untrusted sources.
- **Two patches on top of 1.3.2**, both performance regressions, both submitted
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

## Provenance and reproducing a build

Sources come from the [`cvehound`
branch](https://github.com/evdenis/coccinelle/tree/cvehound) of the coccinelle
fork — coccinelle 1.3.2 plus the two patches above, nothing else. Every wheel
records the exact commit in `BUILD-INFO` and in `COCCINELLE_COMMIT`.

To rebuild locally (needs podman or docker):

```shell
./build-in-container.sh          # -> dist/bundle-<arch>/
./make_wheel.py --bundle dist/bundle-$(uname -m)
```

`build.sh` is what runs inside the `manylinux_2_28` image; it fails the build if
the binary picks up a non-glibc dependency, needs a glibc newer than 2.28, or
turns out to have Python support.

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
