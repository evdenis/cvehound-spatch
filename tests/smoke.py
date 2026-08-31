#!/usr/bin/env python3
"""Verify an *installed* cvehound-spatch wheel.

    python tests/smoke.py [--rules <dir>]

Checks, in order: the package resolves its payload, the binary runs, it is
python-less, it links against nothing but the platform libc, it detects the
fixture the way CVEhound expects, and -- when a rule corpus is reachable --
every CVEhound rule still parses on it. Exits non-zero on the first failure.

The rule corpus comes from ``--rules``, else from an installed cvehound
(``cvehound.content.resolve_content()``), else that step is skipped with a note.
"""

from __future__ import annotations  # the oldest interpreter this must run on is 3.9

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent / 'fixtures'
# Anything outside these sets means the wheel is not as portable as its tag says.
# pre-2.34 glibc splits libdl/libpthread/librt out of libc; all are core glibc.
ALLOWED_LIBS_LINUX = ('linux-vdso', 'libm.so', 'libc.so', 'libdl.so', 'libpthread.so', 'librt.so', 'ld-linux')
# libSystem is macOS's glibc, and a python-less, pcre-less build needs no more.
ALLOWED_LIBS_MACOS = ('/usr/lib/libSystem.B.dylib',)

failures = []


def check(name: str, ok: bool, detail: str = '') -> None:
    print(f'{"ok  " if ok else "FAIL"}  {name}' + (f'  [{detail}]' if detail else ''))
    if not ok:
        failures.append(name)


def spatch_run(spatch: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(spatch), *args], capture_output=True, text=True, check=False)


def unexpected_libraries(spatch: Path) -> list:
    """Shared libraries the binary links that its platform tag does not cover.

    macOS has no ldd; otool -L is the equivalent, and it repeats the file's own
    name on the first line before listing the dependencies.

    A missing or failing inspector is reported as a finding rather than swallowed:
    empty output would otherwise make this check pass without inspecting anything.
    """
    darwin = sys.platform == 'darwin'
    argv = ['otool', '-L', str(spatch)] if darwin else ['ldd', str(spatch)]
    try:
        run = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as exc:
        return [f'cannot run {argv[0]}: {exc}']
    if run.returncode != 0:
        return [f'{argv[0]} failed (rc={run.returncode}): {run.stderr.strip() or run.stdout.strip()}']
    lines = run.stdout.splitlines()
    if darwin:
        deps, allowed = lines[1:], ALLOWED_LIBS_MACOS
    else:
        deps, allowed = [line for line in lines if '=>' in line], ALLOWED_LIBS_LINUX
    return [
        line.strip() for line in deps if line.strip() and not any(lib in line for lib in allowed)
    ]


def detect(spatch: Path, rule: Path, source: Path) -> str:
    """Run one rule the way cvehound does; the diff on stdout is the verdict."""
    run = spatch_run(
        spatch,
        '--no-includes',
        '--include-headers',
        '-D',
        'detect',
        '--very-quiet',
        '--cocci-file',
        str(rule),
        str(source),
    )
    if run.returncode != 0:
        raise SystemExit(f'spatch failed on {source.name}: rc={run.returncode}\n{run.stderr}')
    return run.stdout.strip()


def find_rules(explicit: str | None) -> Path | None:
    if explicit:
        return Path(explicit)
    try:
        from cvehound.content import resolve_content
    except ImportError:
        return None
    return Path(resolve_content().rules_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rules', help='CVEhound rule directory (default: from installed cvehound)')
    args = parser.parse_args()

    import cvehound_spatch

    spatch = cvehound_spatch.spatch_path()
    print(f'cvehound-spatch {cvehound_spatch.__version__} at {spatch.parent}')

    check('binary is present and executable', os.access(spatch, os.X_OK), str(spatch))
    check('standard.iso is adjacent', cvehound_spatch.iso_file().parent == spatch.parent)
    check('standard.h is adjacent', cvehound_spatch.macro_file().parent == spatch.parent)

    version = spatch_run(spatch, '--version')
    check('spatch --version runs', version.returncode == 0, version.stdout.splitlines()[0] if version.stdout else version.stderr)
    check(
        'version matches the packaged metadata',
        cvehound_spatch.COCCINELLE_VERSION in version.stdout,
        cvehound_spatch.COCCINELLE_VERSION,
    )
    # A python-enabled build would report "yes" here -- and would drag the
    # libpython dlopen failure mode back in.
    check('built without Python scripting', 'Python scripting support: no' in version.stdout)

    unexpected = unexpected_libraries(spatch)
    check('links against the platform libc only', not unexpected, '; '.join(unexpected))

    # spatch prints its context-mode output by running diff(1); without it the
    # run still exits 0 and reports nothing, which is the worst way to fail.
    diff = shutil.which('diff')
    check('diff(1) is available', diff is not None, diff or 'install diffutils')

    rule = FIXTURES / 'rule.cocci'
    check('fixture: vulnerable source reports', bool(detect(spatch, rule, FIXTURES / 'vulnerable.c')))
    check('fixture: fixed source stays silent', not detect(spatch, rule, FIXTURES / 'fixed.c'))

    rules_dir = find_rules(args.rules)
    if rules_dir is None:
        print('skip  CVEhound rule corpus (cvehound not installed, no --rules)')
    else:
        cocci = sorted(rules_dir.rglob('*.cocci'))
        broken = [
            path.name
            for path in cocci
            if spatch_run(spatch, '--parse-cocci', str(path)).returncode != 0
        ]
        check(f'all {len(cocci)} CVEhound rules parse', cocci and not broken, ', '.join(broken[:5]))

    if failures:
        print(f'\n{len(failures)} check(s) failed: {", ".join(failures)}')
        return 1
    print('\nall checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
