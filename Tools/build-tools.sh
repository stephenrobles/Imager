#!/bin/zsh
# Builds the image optimizers Imager bundles, as universal (arm64 + x86_64) executables in
# Helpers/, plus the SVGO JavaScript bundle in Imager/Resources/svgo.js.
#
# Usage:  Tools/build-tools.sh [tool …]
#   With no arguments every tool is built. Otherwise only the named ones: optipng pngcrush
#   zopflipng advpng pngquant mozjpeg jpegoptim gifsicle svgo.
#
# Sources are fetched into build/tools/src (git tags and release tarballs pinned below) the
# first time, and built in build/tools/work. Needs Xcode's clang, autoconf/automake (Homebrew)
# for gifsicle and advancecomp, and node/npm for SVGO. No Rust or cmake.
#
# The binaries are checked into git so the app builds without this script; rerun it after
# bumping a version below.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SRC="$ROOT/build/tools/src"
WORK="$ROOT/build/tools/work"
PREFIX="$WORK/prefix"
OUT="$ROOT/Helpers"
MIN_MACOS=26.0
ARCHS=(-arch arm64 -arch x86_64)
ARCHFLAGS="${ARCHS[*]} -mmacosx-version-min=$MIN_MACOS"
CFLAGS_COMMON="$ARCHFLAGS -O2 -DNDEBUG -fno-common"
LDFLAGS_COMMON="$ARCHFLAGS -Wl,-dead_strip"
JOBS=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
export CC=clang CXX=clang++

# Pinned versions.
GIFSICLE_TAG=v1.96
JPEGOPTIM_REF=master            # 1.5.7 development; the last tagged release lacks fixes we want
PNGQUANT_TAG=2.18.0             # the last C version (3.x is Rust)
LIBIMAGEQUANT_TAG=2.18.0        # the C library pngquant 2.x needs
ADVANCECOMP_TAG=v2.6
OPTIPNG_VERSION=0.7.8
PNGCRUSH_VERSION=1.8.13
MOZJPEG_REPO=https://github.com/ImageOptim/mozjpeg-cocoa   # mozjpeg 4.1.5 with ImageOptim's config
ZOPFLI_REPO=https://github.com/ImageOptim/zopfli           # zopfli with --timelimit and --lossy_transparent
SVGO_VERSION=4.1.0
ESBUILD_VERSION=0.28.2

mkdir -p "$SRC" "$WORK" "$PREFIX/include" "$PREFIX/lib" "$OUT"

log() { print -P "%F{cyan}▶%f $*"; }

fetch_git() { # name url [ref]
  local name=$1 url=$2 ref=${3:-}
  [[ -d "$SRC/$name" ]] && return
  log "Fetching $name"
  if [[ -n "$ref" ]]; then
    git clone -q --depth 1 --branch "$ref" "$url" "$SRC/$name"
  else
    git clone -q --depth 1 "$url" "$SRC/$name"
  fi
  rm -rf "$SRC/$name/.git"
}

fetch_tar() { # name url
  local name=$1 url=$2
  [[ -d "$SRC/$name" ]] && return
  log "Fetching $name"
  mkdir -p "$SRC/$name"
  curl -sSL "$url" | tar xz -C "$SRC/$name" --strip-components=1
}

fetch_all() {
  fetch_tar optipng "https://downloads.sourceforge.net/project/optipng/OptiPNG/optipng-$OPTIPNG_VERSION/optipng-$OPTIPNG_VERSION.tar.gz"
  fetch_tar pngcrush "https://downloads.sourceforge.net/project/pmt/pngcrush/$PNGCRUSH_VERSION/pngcrush-$PNGCRUSH_VERSION.tar.gz"
  fetch_git zopfli "$ZOPFLI_REPO"
  fetch_git advancecomp https://github.com/amadvance/advancecomp "$ADVANCECOMP_TAG"
  fetch_git pngquant https://github.com/kornelski/pngquant "$PNGQUANT_TAG"
  fetch_git libimagequant https://github.com/ImageOptim/libimagequant "$LIBIMAGEQUANT_TAG"
  fetch_git mozjpeg "$MOZJPEG_REPO"
  fetch_git jpegoptim https://github.com/tjko/jpegoptim "$JPEGOPTIM_REF"
  fetch_git gifsicle https://github.com/kohler/gifsicle "$GIFSICLE_TAG"
}

# Copies a source tree into the work dir so the sources stay pristine.
stage() { # name
  rm -rf "$WORK/$1"
  cp -R "$SRC/$1" "$WORK/$1"
}

install_bin() { # path name
  strip -x "$1" 2>/dev/null || true
  cp "$1" "$OUT/$2"
  chmod 755 "$OUT/$2"
  codesign --force --sign - "$OUT/$2"
  lipo -archs "$OUT/$2" | sed "s/^/   $2: /"
}

# ---------------------------------------------------------------------------------------------
# optipng (also provides the universal static libpng + zlib the other PNG tools link against)
build_optipng() {
  log "Building optipng"
  stage optipng
  cd "$WORK/optipng"
  # -Dfdopen=fdopen: the bundled zlib's zutil.h mistakes Apple's TARGET_OS_MAC for classic Mac OS.
  CFLAGS="$CFLAGS_COMMON -Dfdopen=fdopen -Wno-everything" LDFLAGS="$LDFLAGS_COMMON" ./configure > /dev/null
  make -j"$JOBS" > /dev/null
  install_bin src/optipng/optipng optipng
  cp third_party/libpng/png.h third_party/libpng/pngconf.h third_party/libpng/pnglibconf.h "$PREFIX/include/"
  cp third_party/zlib/zlib.h third_party/zlib/zconf.h "$PREFIX/include/"
  cp third_party/libpng/libpng.a "$PREFIX/lib/libpng.a"
  cp third_party/zlib/libz.a "$PREFIX/lib/libz.a"
}

# ---------------------------------------------------------------------------------------------
build_pngcrush() {
  log "Building pngcrush"
  stage pngcrush
  cd "$WORK/pngcrush"
  # The bundled libpng/zlib headers mistake Apple's TARGET_OS_MAC for classic Mac OS.
  sed -i '' 's/defined(TARGET_OS_MAC)/0/' pngpriv.h zutil.h
  make -f Makefile CC=clang LD=clang \
    CFLAGS="$CFLAGS_COMMON -std=gnu99 -funroll-loops -fomit-frame-pointer -Wno-everything" \
    CPPFLAGS="-DLIBPNG_UNIFIED -I. -DNO_GZ -DPNGCRUSH_TIMERS=11 -DPNGCRUSH_USE_CLOCK_GETTIME=1 -DPNG_ARM_NEON_OPT=0 -DPNG_INTEL_SSE_OPT=0" \
    LDFLAGS="$LDFLAGS_COMMON" pngcrush > /dev/null
  install_bin pngcrush pngcrush
}

# ---------------------------------------------------------------------------------------------
build_zopflipng() {
  log "Building zopflipng"
  stage zopfli
  cd "$WORK/zopfli"
  local objs=()
  for f in src/zopfli/{blocksplitter,cache,deflate,gzip_container,hash,katajainen,lz77,squeeze,tree,util,zlib_container,zopfli_lib}.c; do
    clang $=CFLAGS_COMMON -Wno-everything -c "$f" -o "${f:t:r}.o"
    objs+=("${f:t:r}.o")
  done
  for f in src/zopflipng/lodepng/{lodepng,lodepng_util}.cpp src/zopflipng/zopflipng_bin.cc src/zopflipng/zopflipng_lib.cc; do
    clang++ $=CFLAGS_COMMON -std=c++11 -Wno-everything -c "$f" -o "${f:t:r}.o"
    objs+=("${f:t:r}.o")
  done
  clang++ $=LDFLAGS_COMMON -o zopflipng "${objs[@]}"
  install_bin zopflipng zopflipng
}

# ---------------------------------------------------------------------------------------------
build_advpng() {
  log "Building advpng"
  stage advancecomp
  cd "$WORK/advancecomp"
  sh autogen.sh > /dev/null 2>&1
  CFLAGS="$CFLAGS_COMMON -Wno-everything" CXXFLAGS="$CFLAGS_COMMON -Wno-everything" LDFLAGS="$LDFLAGS_COMMON" \
    ./configure --disable-bzip2 > /dev/null
  make -j"$JOBS" advpng > /dev/null
  install_bin advpng advpng
}

# ---------------------------------------------------------------------------------------------
# A full-featured libpng (optipng's copy is built with a trimmed configuration) for pngquant.
build_libpng() {
  log "Building libpng (full configuration)"
  rm -rf "$WORK/libpng"
  cp -R "$SRC/optipng/third_party/libpng" "$WORK/libpng"
  cd "$WORK/libpng"
  sed -i '' 's/defined(TARGET_OS_MAC)/0/' pngpriv.h
  CFLAGS="$CFLAGS_COMMON -Wno-everything" LDFLAGS="$LDFLAGS_COMMON" \
    ./configure --disable-shared --enable-arm-neon=no --enable-intel-sse=no > /dev/null
  make -j"$JOBS" libpng16.la > /dev/null
  mkdir -p "$PREFIX/full"
  cp .libs/libpng16.a png.h pngconf.h pnglibconf.h "$PREFIX/full/"
}

build_pngquant() {
  [[ -f "$PREFIX/full/libpng16.a" ]] || build_libpng
  log "Building pngquant"
  # libimagequant first, on its own, so it gets the universal flags (pngquant's configure would
  # rebuild it without them). SSE is off because the same objects are built for arm64.
  stage libimagequant
  cd "$WORK/libimagequant"
  CFLAGS="$CFLAGS_COMMON -Wno-everything" LDFLAGS="$LDFLAGS_COMMON" ./configure --disable-sse > /dev/null
  make -j"$JOBS" static > /dev/null
  stage pngquant
  cd "$WORK/pngquant"
  # Cocoa reads the PNG through ImageIO so embedded color profiles are applied; no lcms2 needed.
  CFLAGS="$CFLAGS_COMMON -Wno-everything" LDFLAGS="$LDFLAGS_COMMON" \
    ./configure --disable-sse --with-cocoa --without-lcms2 --with-libpng="$PREFIX/full" \
      --with-libimagequant="$WORK/libimagequant" > /dev/null
  make -j"$JOBS" > /dev/null
  install_bin pngquant pngquant
}

# ---------------------------------------------------------------------------------------------
# mozjpeg's libjpeg (static, for jpegoptim) and its jpegtran
build_mozjpeg() {
  log "Building mozjpeg (libjpeg + jpegtran)"
  stage mozjpeg
  cd "$WORK/mozjpeg"
  cp "$ROOT/Tools/mozjpeg-config/jconfig.h" "$ROOT/Tools/mozjpeg-config/jconfigint.h" "$ROOT/Tools/mozjpeg-config/jversion.h" .
  # The library proper, without SIMD (arithmetic coding is off in jconfig.h; the *ext.c files
  # are #included by others rather than compiled on their own).
  local libobjs=()
  for f in jcapimin jcapistd jccoefct jccolor jcdctmgr jcext jchuff jcicc jcinit jcmainct jcmarker \
           jcmaster jcomapi jcparam jcphuff jcprepct jcsample jctrans jdapimin jdapistd jdatadst \
           jdatasrc jdcoefct jdcolor jddctmgr jdhuff jdicc jdinput jdmainct jdmarker jdmaster jdmerge \
           jdphuff jdpostct jdsample jdtrans jerror jfdctflt jfdctfst jfdctint jidctflt jidctfst \
           jidctint jidctred jmemmgr jmemnobs jquant1 jquant2 jsimd_none jutils; do
    [[ -f "$f.c" ]] || continue
    clang $=CFLAGS_COMMON -Wno-everything -I. -c "$f.c" -o "$f.o"
    libobjs+=("$f.o")
  done
  libtool -static -o libjpeg.a "${libobjs[@]}" 2> /dev/null
  cp libjpeg.a "$PREFIX/lib/libjpeg.a"
  cp jpeglib.h jconfig.h jmorecfg.h jerror.h "$PREFIX/include/"
  local binobjs=()
  for f in jpegtran.c cdjpeg.c rdswitch.c transupp.c; do
    clang $=CFLAGS_COMMON -Wno-everything -I. -c "$f" -o "bin_${f:r}.o"
    binobjs+=("bin_${f:r}.o")
  done
  clang $=LDFLAGS_COMMON -o jpegtran "${binobjs[@]}" libjpeg.a
  install_bin jpegtran jpegtran
}

# ---------------------------------------------------------------------------------------------
build_jpegoptim() {
  log "Building jpegoptim"
  stage jpegoptim
  cd "$WORK/jpegoptim"
  CFLAGS="$CFLAGS_COMMON -Wno-everything" CPPFLAGS="-I$PREFIX/include" LDFLAGS="$LDFLAGS_COMMON -L$PREFIX/lib" \
    ./configure > /dev/null
  make -j"$JOBS" jpegoptim > /dev/null
  install_bin jpegoptim jpegoptim
}

# ---------------------------------------------------------------------------------------------
build_gifsicle() {
  log "Building gifsicle"
  stage gifsicle
  cd "$WORK/gifsicle"
  sh bootstrap.sh > /dev/null 2>&1
  CFLAGS="$CFLAGS_COMMON -Wno-everything" LDFLAGS="$LDFLAGS_COMMON" \
    ./configure --disable-gifview --disable-gifdiff > /dev/null
  make -j"$JOBS" -C src gifsicle > /dev/null
  install_bin src/gifsicle gifsicle
}

# ---------------------------------------------------------------------------------------------
# SVGO runs inside the app through JavaScriptCore; esbuild wraps its browser build into one
# script that exposes `ImagerSVGO.optimize(svg, config)`.
build_svgo() {
  log "Building svgo.js"
  local dir="$WORK/svgo"
  mkdir -p "$dir"
  cd "$dir"
  [[ -f package.json ]] || npm init -y > /dev/null
  npm install --silent --no-audit --no-fund "svgo@$SVGO_VERSION" "esbuild@$ESBUILD_VERSION"
  cat > entry.js <<'EOF'
import { optimize, VERSION } from "svgo/browser";
globalThis.ImagerSVGO = { optimize, version: VERSION };
EOF
  ./node_modules/.bin/esbuild entry.js --bundle --format=iife --platform=browser --target=es2022 --minify \
    --outfile="$ROOT/Imager/Resources/svgo.js" --log-level=warning
  ls -la "$ROOT/Imager/Resources/svgo.js" | awk '{print "   svgo.js:", $5, "bytes"}'
}

# ---------------------------------------------------------------------------------------------
fetch_all
tools=("$@")
[[ ${#tools} -eq 0 ]] && tools=(optipng pngcrush zopflipng advpng pngquant mozjpeg jpegoptim gifsicle svgo)
for tool in "${tools[@]}"; do
  "build_$tool"
done
log "Done. Helpers:"
ls -la "$OUT"
