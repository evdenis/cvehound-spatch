"""Run the bundled spatch, or ask where it is.

    python -m cvehound_spatch --path        # print the binary's path and exit
    python -m cvehound_spatch --build-info  # print the build provenance
    python -m cvehound_spatch <args...>     # exec spatch with these arguments

Everything except the two flags above is handed to spatch untouched, so
``python -m cvehound_spatch --version`` reports coccinelle's version, not this
package's.
"""

import os
import sys

from cvehound_spatch import BUILD_INFO, __version__, spatch_path


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] == '--path':
        print(spatch_path())
        return
    if args and args[0] == '--build-info':
        print(f'cvehound-spatch: {__version__}')
        for key, value in BUILD_INFO.items():
            print(f'{key}: {value}')
        return
    spatch = str(spatch_path())
    os.execv(spatch, [spatch, *args])


if __name__ == '__main__':
    main()
