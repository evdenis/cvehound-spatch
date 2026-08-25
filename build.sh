#!/bin/bash
# Build the tailored, relocatable spatch bundle that the wheel ships.
#
# Runs INSIDE quay.io/pypa/manylinux_2_28_<arch> (AlmaLinux 8, glibc 2.28).
# Use build-in-container.sh on the host.
#
# The build configuration is not a menu: every flag below was decided by
# measurement (see README.md, "Choices made"). The knobs that remain are the
# source to build and where to put the result.
set -euo pipefail

COCCINELLE_REPO=${COCCINELLE_REPO:-https://github.com/evdenis/coccinelle.git}
COCCINELLE_REF=${COCCINELLE_REF:-cvehound}
OCAML_VERSION=${OCAML_VERSION:-5.3.0}
JOBS=${JOBS:-$(nproc)}
OPAM_VERSION=${OPAM_VERSION:-2.2.1}
export OPAMROOT=${OPAMROOT:-/opam/root}   # mount a host dir at /opam to cache the switch
OPAMBIN=${OPAMBIN:-/opam/bin}

HERE=$(cd "$(dirname "$0")" && pwd)
ARCH=$(uname -m)
OUT=${OUT:-$HERE/dist/bundle-$ARCH}
WORK=${WORK:-/tmp/cocci-build-$ARCH}

echo "== bundle: $ARCH (ocaml $OCAML_VERSION, $COCCINELLE_REPO@$COCCINELLE_REF)"

# --- toolchain ---------------------------------------------------------------
# The manylinux images already carry everything autogen/configure need; only
# reach for dnf (and the network) if something is actually missing.
declare -A PKG=([autoconf]=autoconf [automake]=automake [m4]=m4 [diff]=diffutils [file]=file)
missing=()
for tool in "${!PKG[@]}"; do
    command -v "$tool" >/dev/null || missing+=("${PKG[$tool]}")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "== installing: ${missing[*]}"
    dnf install -y -q "${missing[@]}" >/dev/null
fi

mkdir -p "$OPAMBIN"
if [ ! -x "$OPAMBIN/opam" ]; then
    # opam's release assets call aarch64 "arm64"
    [ "$ARCH" = aarch64 ] && OPAM_ARCH=arm64 || OPAM_ARCH=$ARCH
    curl -fsSL -o "$OPAMBIN/opam" \
        "https://github.com/ocaml/opam/releases/download/${OPAM_VERSION}/opam-${OPAM_VERSION}-${OPAM_ARCH}-linux"
    chmod +x "$OPAMBIN/opam"
fi
export PATH="$OPAMBIN:$PATH"

if [ ! -d "$OPAMROOT/repo" ]; then
    opam init --bare --disable-sandboxing -n >/dev/null
fi

SWITCH="cocci-$OCAML_VERSION"
if ! opam switch list --short 2>/dev/null | grep -qx "$SWITCH"; then
    opam switch create "$SWITCH" "ocaml-base-compiler.$OCAML_VERSION" -y
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
    --prefix=/stage
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

# The hand-written Makefile is not reliably parallel-safe; retry sequentially.
make -j"$JOBS" opt-only || { echo "== parallel make failed, retrying -j1"; make opt-only; }

rm -rf /stage
make install-spatch >/dev/null

# --- assemble the flat bundle ------------------------------------------------
# spatch resolves standard.iso/standard.h relative to realpath(argv[0]), so a
# flat directory is all the "installation" there is (globals/cocciconfig.ml.in).
rm -rf "$OUT"
mkdir -p "$OUT"
cp /stage/bin/spatch "$OUT/spatch"
cp /stage/lib/coccinelle/standard.h /stage/lib/coccinelle/standard.iso "$OUT/"
strip "$OUT/spatch"

SPATCH_VERSION=$("$OUT/spatch" --version | head -1)
cat > "$OUT/BUILD-INFO" <<EOF
coccinelle_repo: $COCCINELLE_REPO
coccinelle_ref: $COCCINELLE_REF
coccinelle_sha: $COCCINELLE_SHA
spatch_version: $SPATCH_VERSION
ocaml_version: $(ocamlopt -version)
configure_flags: ${CONFIGURE_FLAGS[*]}
build_image: manylinux_2_28_$ARCH
EOF

# --- sanity checks -----------------------------------------------------------
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
# A python-less build must say so: a rule with script:python has to fail loudly
# rather than silently report nothing.
if "$OUT/spatch" --version | grep -q '^Python scripting support: yes'; then
    echo "ERROR: this build has Python support" >&2
    exit 1
fi

cat "$OUT/BUILD-INFO"
du -sh "$OUT" "$OUT/spatch"
echo "== OK: $OUT"
