#!/bin/bash
# Build the tailored, relocatable spatch bundle that the wheel ships.
#
# Linux: runs INSIDE quay.io/pypa/manylinux_2_28_<arch> (AlmaLinux 8, glibc
#   2.28). Use build-in-container.sh on the host.
# macOS: runs directly on the host. There is no container to build against and
#   none is needed -- libSystem is the only library a tailored spatch links,
#   and "portable" here means the deployment target, which is set below.
#
# The build configuration is not a menu: every flag below was decided by
# measurement (see README.md, "Choices made"). The knobs that remain are the
# source to build and where to put the result.
#
# Written for bash 3.2: that is what /bin/bash is on macOS, so no associative
# arrays and no ${var,,}.
set -euo pipefail

COCCINELLE_REPO=${COCCINELLE_REPO:-https://github.com/evdenis/coccinelle.git}
COCCINELLE_REF=${COCCINELLE_REF:-cvehound}
OCAML_VERSION=${OCAML_VERSION:-5.3.0}
OPAM_VERSION=${OPAM_VERSION:-2.2.1}

HERE=$(cd "$(dirname "$0")" && pwd)
OS=$(uname -s)
ARCH=$(uname -m)
OUT=${OUT:-$HERE/dist/bundle-$ARCH}
WORK=${WORK:-/tmp/cocci-build-$ARCH}

# Everything that differs between build hosts is declared here and nowhere
# else, apart from three things that are steps rather than values: how opam is
# obtained, the macOS re-sign after strip, and the verify_* function.
# PKG_PAIRS is "<command>:<package>" because diffutils is the one package whose
# command name is not its own.
case $OS in
Linux)
    JOBS=${JOBS:-$(nproc)}
    export OPAMROOT=${OPAMROOT:-/opam/root}   # mount a host dir at /opam to cache the switch
    OPAMBIN=${OPAMBIN:-/opam/bin}
    STAGE=${STAGE:-/stage}
    # The manylinux images already carry everything autogen/configure need.
    PKG_PAIRS="autoconf:autoconf automake:automake m4:m4 diff:diffutils file:file"
    PKG_INSTALL="dnf install -y -q"
    PLATFORM_TAG="manylinux_2_28_$ARCH"
    BUILD_HOST="quay.io/pypa/manylinux_2_28_$ARCH"
    ;;
Darwin)
    JOBS=${JOBS:-$(sysctl -n hw.logicalcpu)}
    # No /opam bind mount to stand on; cache the switch where CI can restore it.
    export OPAMROOT=${OPAMROOT:-${CACHE:-$HOME/.cache/cvehound-spatch-build}/root}
    # / is a sealed read-only volume, so the Linux /stage cannot exist. Nothing
    # is baked into the binary from the prefix: spatch resolves standard.iso
    # relative to realpath(argv[0]) (globals/cocciconfig.ml.in).
    STAGE=${STAGE:-/tmp/cocci-stage-$ARCH}
    # m4, diff and file are in the base system; autoconf/automake and opam are
    # not. The runner's formula index is always stale and none of these needs
    # to be current, so do not let a `brew install` turn into a `brew update`.
    PKG_PAIRS="autoconf:autoconf automake:automake opam:opam"
    PKG_INSTALL="brew install"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
    # The oldest macOS the wheel claims to run on. Exported before the switch is
    # created so the OCaml runtime's own C objects carry it too -- set it only
    # at link time and they would still be stamped with the SDK's version.
    export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}
    # The tag is derived from the target, not hardcoded, so the two cannot
    # disagree; verify_darwin then asserts the binary's minos against it.
    PLATFORM_TAG="macosx_${MACOSX_DEPLOYMENT_TARGET//./_}_$ARCH"
    BUILD_HOST="macOS $(sw_vers -productVersion)"
    ;;
*)
    echo "unsupported build host: $OS" >&2
    exit 1
    ;;
esac

echo "== bundle: $OS/$ARCH (ocaml $OCAML_VERSION, $COCCINELLE_REPO@$COCCINELLE_REF)"

# --- toolchain ---------------------------------------------------------------
# Only reach for the package manager (and the network) if something is missing.
missing=()
for pair in $PKG_PAIRS; do
    command -v "${pair%%:*}" >/dev/null || missing+=("${pair#*:}")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "== installing: ${missing[*]}"
    $PKG_INSTALL "${missing[@]}"
fi

# opam is a package everywhere but the manylinux image, which has none; there it
# comes from the release binary, into the same directory the switch is cached in.
if [ "$OS" = Linux ]; then
    mkdir -p "$OPAMBIN"
    if [ ! -x "$OPAMBIN/opam" ]; then
        # opam's release assets call aarch64 "arm64"
        [ "$ARCH" = aarch64 ] && OPAM_ARCH=arm64 || OPAM_ARCH=$ARCH
        curl -fsSL -o "$OPAMBIN/opam" \
            "https://github.com/ocaml/opam/releases/download/${OPAM_VERSION}/opam-${OPAM_VERSION}-${OPAM_ARCH}-linux"
        chmod +x "$OPAMBIN/opam"
    fi
    export PATH="$OPAMBIN:$PATH"
fi

if [ ! -d "$OPAMROOT/repo" ]; then
    opam init --bare --disable-sandboxing -n >/dev/null
fi

# flambda: measured at -4.5% CPU on a 490-rule scan and -5.3% under the zygote
# transport (README.md, "Choices made"). It costs +11.4MB of binary, which is
# only a per-exec page-in tax -- +428 minor faults, 0.05ms -- so it does not
# pay that back per invocation. no-compression is --without-zstd, which keeps
# libzstd out of the binary on any host that has it (README.md, same section).
#
# The switch name carries the variants, so changing this set does not silently
# reuse a switch built from the old one out of a cached OPAMROOT.
SWITCH="cocci-$OCAML_VERSION-flambda-nozstd"
if ! opam switch list --short 2>/dev/null | grep -qx "$SWITCH"; then
    opam switch create "$SWITCH" -y --packages="\
ocaml-variants.$OCAML_VERSION+options,ocaml-option-flambda,ocaml-option-no-compression"
fi
# coccinelle's bundles/ carry menhir, parmap and stdcompat; ocamlfind is the
# only thing configure needs from opam.
opam install -y --switch="$SWITCH" ocamlfind >/dev/null
eval "$(opam env --switch="$SWITCH" --set-switch)"
echo "== ocaml: $(ocamlopt -version)"

# --- sources -----------------------------------------------------------------
rm -rf "$WORK"
git clone -q "$COCCINELLE_REPO" "$WORK"
# Resolve first: checking out a remote-only branch name by DWIM would create a
# local branch, which --detach refuses. This accepts a branch, tag or SHA.
COCCINELLE_SHA=$(git -C "$WORK" rev-parse --verify -q "origin/$COCCINELLE_REF^{commit}" \
    || git -C "$WORK" rev-parse --verify "$COCCINELLE_REF^{commit}")
git -C "$WORK" checkout -q --detach "$COCCINELLE_SHA"
echo "== coccinelle: $COCCINELLE_SHA"

# --- configure + make --------------------------------------------------------
cd "$WORK"
./autogen --ignore_localversion

CONFIGURE_FLAGS=(
    --prefix="$STAGE"
    --disable-python
    --disable-ocaml
    --disable-pcre-syntax
    --without-bash-completion
    --without-metainfo
)
./configure "${CONFIGURE_FLAGS[@]}"

# Bounds checks are worth ~1% here, so drop coccinelle's default -unsafe:
# Makefile.config uses ?= for both variables, so the environment wins.
export OCAMLCFLAGS='-w @42' OPTFLAGS='-w @42'

# -O3 is where flambda's win was measured; the level is set through OCAMLPARAM
# because coccinelle's Makefile has no hook for it.
export OCAMLPARAM="_,O3=1"

# The hand-written Makefile is not reliably parallel-safe; retry sequentially.
make -j"$JOBS" opt-only || { echo "== parallel make failed, retrying -j1"; make opt-only; }

rm -rf "$STAGE"
make install-spatch >/dev/null

# --- assemble the flat bundle ------------------------------------------------
# spatch resolves standard.iso/standard.h relative to realpath(argv[0]), so a
# flat directory is all the "installation" there is (globals/cocciconfig.ml.in).
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$STAGE/bin/spatch" "$OUT/spatch"
cp "$STAGE/lib/coccinelle/standard.h" "$STAGE/lib/coccinelle/standard.iso" "$OUT/"
strip "$OUT/spatch"
if [ "$OS" = Darwin ]; then
    # An arm64 binary without a valid signature is killed on exec. Apple's strip
    # re-signs what it rewrites, but that is a property of the toolchain version
    # rather than a guarantee, so re-sign ad-hoc and let verify_darwin check it.
    codesign --sign - --force "$OUT/spatch"
fi

# platform_tag is what make_wheel.py tags the wheel with. It is recorded by the
# build rather than guessed from the bundle directory name later, because the
# arch alone cannot say which OS produced it -- an x86_64 Mac and an x86_64
# Linux box both write "bundle-x86_64".
SPATCH_VERSION=$("$OUT/spatch" --version | head -1)
cat > "$OUT/BUILD-INFO" <<EOF
coccinelle_repo: $COCCINELLE_REPO
coccinelle_ref: $COCCINELLE_REF
coccinelle_sha: $COCCINELLE_SHA
spatch_version: $SPATCH_VERSION
ocaml_version: $(ocamlopt -version)
configure_flags: ${CONFIGURE_FLAGS[*]}
platform_tag: $PLATFORM_TAG
build_host: $BUILD_HOST
EOF

# --- sanity checks -----------------------------------------------------------
verify_linux() {
    echo "== ldd:"
    ldd "$OUT/spatch"
    # pre-2.34 glibc splits libdl/libpthread/librt out of libc; all are core glibc
    if ldd "$OUT/spatch" | grep -vE 'linux-vdso|libm\.so|libc\.so|libdl\.so|libpthread\.so|librt\.so|ld-linux' | grep -q '=>'; then
        echo "ERROR: unexpected shared library dependency" >&2
        exit 1
    fi
    MAXGLIBC=$(objdump -T "$OUT/spatch" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
    echo "== max glibc symbol: $MAXGLIBC (must be <= GLIBC_2.28)"
    case "$MAXGLIBC" in
        GLIBC_2.28|GLIBC_2.2[0-7]|GLIBC_2.1?|GLIBC_2.?) ;;
        *) echo "ERROR: exceeds glibc 2.28" >&2; exit 1 ;;
    esac
}

verify_darwin() {
    echo "== otool -L:"
    otool -L "$OUT/spatch"
    # libSystem is macOS's glibc, and with --disable-python/--disable-pcre-syntax
    # it is the only library spatch has any business linking. (The first line of
    # otool -L output is the file name, not a dependency.)
    if otool -L "$OUT/spatch" | tail -n +2 | grep -v '/usr/lib/libSystem\.B\.dylib' | grep -q .; then
        echo "ERROR: unexpected shared library dependency" >&2
        exit 1
    fi
    # LC_BUILD_VERSION is what the macosx_11_0 wheel tag promises, and dyld
    # refuses to load an executable built for a newer OS than the one running it
    # -- so an unnoticed bump here is a wheel that installs and cannot run.
    MINOS=$(vtool -show-build "$OUT/spatch" | awk '$1 == "minos" { print $2 }')
    echo "== minos: $MINOS (must be $MACOSX_DEPLOYMENT_TARGET)"
    if [ "${MINOS%.0}" != "${MACOSX_DEPLOYMENT_TARGET%.0}" ]; then
        echo "ERROR: built for macOS $MINOS, not $MACOSX_DEPLOYMENT_TARGET" >&2
        exit 1
    fi
    codesign --verify "$OUT/spatch" || {
        echo "ERROR: signature is not valid" >&2
        exit 1
    }
}

case $OS in
Linux)  verify_linux ;;
Darwin) verify_darwin ;;
esac

# A python-less build must say so: a rule with script:python has to fail loudly
# rather than silently report nothing.
if "$OUT/spatch" --version | grep -q '^Python scripting support: yes'; then
    echo "ERROR: this build has Python support" >&2
    exit 1
fi

cat "$OUT/BUILD-INFO"
du -sh "$OUT" "$OUT/spatch"
echo "== OK: $OUT"
