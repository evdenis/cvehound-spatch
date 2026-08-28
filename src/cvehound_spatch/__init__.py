"""A prebuilt Coccinelle ``spatch``, importable from Python.

The binary and its two data files live flat inside this package directory:
spatch resolves ``standard.iso``/``standard.h`` relative to the real path of
its own executable, so keeping them adjacent is what makes the bundle
relocatable -- and what lets callers run it with no extra arguments.

The wheel is built by ``make_wheel.py`` in this project's repository; installing
from a source tree gives you the Python API without a binary, and every accessor
below raises ``FileNotFoundError`` in that case.
"""

from pathlib import Path

try:
    from cvehound_spatch import _build_info  # ty: ignore[unresolved-import]
except ImportError:  # source checkout, no wheel built
    _build_info = None  # ty: ignore[invalid-assignment]

__version__ = getattr(_build_info, '__version__', '0.dev0')
COCCINELLE_VERSION = getattr(_build_info, 'COCCINELLE_VERSION', 'unknown')
COCCINELLE_COMMIT = getattr(_build_info, 'COCCINELLE_COMMIT', 'unknown')
BUILD_INFO: dict[str, str] = getattr(_build_info, 'BUILD_INFO', {})
# Read defensively rather than imported: a wheel packed before this existed has
# a _build_info without it, and that must degrade to "declares nothing" rather
# than take the whole module's metadata down with it.
FEATURES: frozenset[str] = getattr(_build_info, 'FEATURES', frozenset())

__all__ = [
    'BUILD_INFO',
    'COCCINELLE_COMMIT',
    'COCCINELLE_VERSION',
    'FEATURES',
    '__version__',
    'iso_file',
    'macro_file',
    'spatch_path',
]

_HERE = Path(__file__).resolve().parent


def _payload(name: str) -> Path:
    path = _HERE / name
    if not path.exists():
        raise FileNotFoundError(
            f'{name} is missing from {_HERE}: this is a source checkout of '
            'cvehound-spatch, not an installed wheel'
        )
    return path


def spatch_path() -> Path:
    """The bundled spatch executable."""
    return _payload('spatch')


def iso_file() -> Path:
    """standard.iso, the isomorphism file spatch loads by default."""
    return _payload('standard.iso')


def macro_file() -> Path:
    """standard.h, the builtin macro definitions."""
    return _payload('standard.h')
