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
import re
import shutil
import struct
import subprocess
import sys
import tempfile
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


SUMMARY_RE = re.compile(r'^SPATCH-SUMMARY (.*)$', re.MULTILINE)


def summary(stderr: str) -> dict:
    """The one SPATCH-SUMMARY line as a dict of ints; {} when absent or repeated."""
    lines = SUMMARY_RE.findall(stderr)
    if len(lines) != 1:
        return {}
    return {key: int(value) for key, value in (pair.split('=') for pair in lines[0].split())}


def scan_dir(spatch: Path, tree: Path, *extra: str) -> subprocess.CompletedProcess:
    rule = FIXTURES / 'rule.cocci'
    return spatch_run(
        spatch, '--no-includes', '--include-headers', '-D', 'detect', '--very-quiet',
        *extra, '--cocci-file', str(rule), '--dir', str(tree),
    )


def fixture_tree(root: Path) -> Path:
    tree = root / 'tree'
    tree.mkdir()
    for name in ('vulnerable.c', 'fixed.c'):
        shutil.copy(FIXTURES / name, tree / name)
    return tree


def zygote_request(proc: subprocess.Popen, capture: str, env: list, argv: list) -> str:
    """One request in the zygote framing: u32 BE field count, u32-prefixed fields."""
    fields = [capture.encode(), str(len(env)).encode(), *(e.encode() for e in env), *(a.encode() for a in argv)]
    proc.stdin.write(struct.pack('>I', len(fields)) + b''.join(struct.pack('>I', len(f)) + f for f in fields))
    proc.stdin.flush()
    (length,) = struct.unpack('>I', proc.stdout.read(4))
    return proc.stdout.read(length).decode()


def feature_checks(spatch: Path, features: frozenset, build_info: dict) -> None:
    """What the build advertises, checked against what it does. Each check runs
    only when its token is declared, so an older wheel still passes."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        tree = fixture_tree(root)
        if 'summary' in features:
            run = scan_dir(spatch, tree)
            got = summary(run.stderr)
            check('summary: one SPATCH-SUMMARY line ends a scan', bool(got), run.stderr[-300:])
            if got:
                check(
                    'summary: groups = handled + skipped + dropped, nothing dropped',
                    got['groups'] == 2 and got['dropped'] == 0
                    and got['groups'] == got['handled'] + got['skipped'] + got['dropped'],
                    str(got),
                )
        if 'cache-selfheal' in features:
            cache = root / 'ast'
            scan_dir(spatch, tree, '--cache-prefix', str(cache))
            entries = [e for e in cache.rglob('vulnerable.c.ast_raw')]
            check('cache-selfheal: a scan writes the entry', len(entries) == 1)
            if entries:
                os.truncate(entries[0], 100)
                run = scan_dir(spatch, tree, '--cache-prefix', str(cache))
                check('cache-selfheal: a torn entry still reports', bool(run.stdout.strip()))
                check('cache-selfheal: the entry is rewritten', entries[0].stat().st_size > 100)
        if 'cache-buildid' in features:
            last = spatch_run(spatch, '--version').stdout.strip().splitlines()[-1]
            check('cache-buildid: --version ends with Build:', last.startswith('Build: '), last)
            if build_info.get('build_id'):
                check('cache-buildid: the banner names the packaged build', last == f'Build: {build_info["build_id"]}', last)
        if 'summary' in features and os.geteuid() != 0:
            # root reads a 0000 file, so the unreadable case cannot be made there
            locked = tree / 'locked.c'
            shutil.copy(FIXTURES / 'vulnerable.c', locked)
            locked.chmod(0)
            try:
                run = scan_dir(spatch, tree)
                got = summary(run.stderr)
                check('summary: an unreadable file is named in a SPATCH-DROP line', 'SPATCH-DROP kind=unreadable' in run.stderr)
                check('summary: and counted, with the exit code unchanged',
                      got.get('unreadable') == 1 and run.returncode == 0, f'rc={run.returncode} {got}')
            finally:
                locked.chmod(0o644)
                locked.unlink()
        if 'zygote-v2' in features:
            proc = subprocess.Popen([str(spatch), '--zygote'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            argv = ['--no-includes', '-D', 'detect', '--very-quiet', '--cocci-file',
                    str(FIXTURES / 'rule.cocci'), str(tree / 'vulnerable.c')]
            try:
                capture = str(root)
                check('zygote: a v1 reply is unchanged', zygote_request(proc, capture, [], argv) == 'exit 0')
                reply = zygote_request(proc, capture, ['COCCI_ZYGOTE_PROTO=2'], argv)
                sizes = tuple(os.path.getsize(root / f'zygote.{n}') for n in ('stdout', 'stderr'))
                check('zygote-v2: the reply carries the capture sizes',
                      reply == 'exit 0 stdout=%d stderr=%d' % sizes, reply)
            finally:
                proc.stdin.close()
                proc.wait(timeout=30)


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

    features = frozenset(getattr(cvehound_spatch, 'FEATURES', ()))
    print(f'features: {" ".join(sorted(features)) or "(none)"}')
    feature_checks(spatch, features, getattr(cvehound_spatch, 'BUILD_INFO', {}))

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
