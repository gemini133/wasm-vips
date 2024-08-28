#!/usr/bin/env bash
set -e

# Working directories
#DEPS=/deps
#TARGET=/target
#mkdir $DEPS
#mkdir $TARGET

SOURCE_DIR=$PWD

# Build within the mounted volume, handy for debugging
# and ensures that dependencies are not being rebuilt
DEPS=$SOURCE_DIR/build/deps
TARGET=$SOURCE_DIR/build/target
rm -rf $DEPS/
mkdir $DEPS
mkdir -p $TARGET

# Define default arguments

# Specifies the environment(s) to target
ENVIRONMENT="web"

# Fixed-width SIMD, enabled by default
# https://github.com/WebAssembly/simd
SIMD=true

# JS BigInt to Wasm i64 integration, enabled by default
# https://github.com/WebAssembly/JS-BigInt-integration
WASM_BIGINT=true

# WebAssembly-based file system layer for Emscripten, disabled by default
# https://github.com/emscripten-core/emscripten/issues/15041
WASM_FS=false

# Leverage Wasm EH instructions for setjmp/longjmp support
# and throwing/catching exceptions, disabled by default
# https://github.com/WebAssembly/exception-handling
WASM_EH=false

# Link-time optimizations (LTO), disabled by default
# https://github.com/emscripten-core/emscripten/issues/10603
LTO=false

# Position Independent Code (PIC), forcefully enabled as required by MAIN_MODULE
# TODO(kleisauke): Remove this once https://github.com/emscripten-core/emscripten/issues/12682 is fixed
PIC=true

# Dynamic loadable modules, enabled by default
MODULES=false

# Support for JPEG XL images, enabled by default
JXL=false

# Support for AVIF, enabled by default
AVIF=false

# Partial support for SVG load via resvg, enabled by default
SVG=false

# Build libvips C++ API, disabled by default
LIBVIPS_CPP=false

# Build bindings, enabled by default but can be disabled if you only need libvips
BINDINGS=true

WEBP=false
TIFF=false

# Parse arguments
while [ $# -gt 0 ]; do
  case $1 in
    --enable-lto) LTO=true ;;
    --enable-wasm-fs) WASM_FS=true ;;
    --enable-wasm-eh) WASM_EH=true ;;
    --disable-simd) SIMD=false ;;
    --disable-wasm-bigint) WASM_BIGINT=false ;;
    --disable-jxl) JXL=false ;;
    --disable-avif) AVIF=false ;;
    --disable-svg) SVG=false ;;
    --disable-modules)
      PIC=false
      MODULES=false
      ;;
    --disable-bindings) BINDINGS=false ;;
    --enable-libvips-cpp) LIBVIPS_CPP=true ;;
    -e|--environment) ENVIRONMENT="$2"; shift ;;
    *) echo "ERROR: Unknown parameter: $1" >&2; exit 1 ;;
  esac
  shift
done

# Configure the ENABLE_* and DISABLE_* expansion helpers
for arg in SIMD WASM_BIGINT JXL AVIF SVG PIC MODULES BINDINGS WEBP TIFF; do
  if [ "${!arg}" = "true" ]; then
    declare ENABLE_$arg=true
  else
    declare DISABLE_$arg=true
  fi
done

# Handy for debugging
#COMMON_FLAGS="-Og -gsource-map -pthread"
export EMCC_DEBUG=1
export EMCC_DEBUG_SAVE=1

# Handy for catching bugs
COMMON_FLAGS="-Os -gsource-map -fsanitize=address -pthread"

# Specify location where source maps are published (browser specific)
#export LDFLAGS+=" --source-map-base http://localhost:3000/lib/"

# Rust flags
export RUSTFLAGS="-Ctarget-feature=+atomics,+bulk-memory,+nontrapping-fptoint -Zdefault-hidden-visibility=yes"

# Common compiler flags
#COMMON_FLAGS="-Oz -pthread"
if [ "$LTO" = "true" ]; then
  COMMON_FLAGS+=" -flto"
  export RUSTFLAGS+=" -Clto -Cembed-bitcode=yes"
fi
if [ "$WASM_EH" = "true" ]; then
  COMMON_FLAGS+=" -fwasm-exceptions -sSUPPORT_LONGJMP=wasm"
  # https://github.com/rust-lang/rust/issues/112195
  export RUSTFLAGS+=" -Cllvm-args=-enable-emscripten-cxx-exceptions=0 -Cllvm-args=-wasm-enable-sjlj"
else
  COMMON_FLAGS+=" -fexceptions"
fi

export CFLAGS="$COMMON_FLAGS -mnontrapping-fptoint -fvisibility=hidden"
if [ "$SIMD" = "true" ]; then
  export CFLAGS+=" -msimd128 -DWASM_SIMD_COMPAT_SLOW"
  export RUSTFLAGS+=" -Ctarget-feature=+simd128"
fi
if [ "$PIC" = "true" ]; then export CFLAGS+=" -fPIC"; fi

export CXXFLAGS="$CFLAGS"

export LDFLAGS="$COMMON_FLAGS -L$TARGET/lib -sAUTO_JS_LIBRARIES=0 -sAUTO_NATIVE_LIBRARIES=0"
if [ "$WASM_BIGINT" = "true" ]; then export LDFLAGS+=" -sWASM_BIGINT"; fi
# FIXME(kleisauke): Workaround for: https://github.com/emscripten-core/emscripten/issues/16836#issuecomment-1556187350
if [ "$LTO" = "true" ]; then export LDFLAGS+=" -Wl,-u,htonl"; fi

# Build paths
export CPATH="$TARGET/include"
export PKG_CONFIG_PATH="$TARGET/lib/pkgconfig"
export EM_PKG_CONFIG_PATH="$PKG_CONFIG_PATH"

# Specific variables for cross-compilation
export CHOST="wasm32-unknown-linux" # wasm32-unknown-emscripten
export MESON_CROSS="$SOURCE_DIR/build/emscripten-crossfile.meson"

# Run as many parallel jobs as there are available CPU cores
export MAKEFLAGS="-j$(nproc)"

# Ensure we link against internal/private dependencies
export PKG_CONFIG="pkg-config --static"

# Ensure Rust build path prefixes are removed from the resulting binaries
# https://reproducible-builds.org/docs/build-path/
# TODO(kleisauke): Switch to -Ztrim-paths=all once supported - https://github.com/rust-lang/rust/issues/111540
export RUSTFLAGS+=" --remap-path-prefix=$(rustc --print sysroot)/lib/rustlib/src/rust/library/="
export RUSTFLAGS+=" --remap-path-prefix=$CARGO_HOME/registry/src/="
export RUSTFLAGS+=" --remap-path-prefix=$DEPS/="

# Dependency version numbers
VERSION_ZLIB_NG=2.2.1       # https://github.com/zlib-ng/zlib-ng
VERSION_FFI=3.4.6           # https://github.com/libffi/libffi
VERSION_GLIB=2.81.1         # https://gitlab.gnome.org/GNOME/glib
VERSION_EXPAT=2.6.2         # https://github.com/libexpat/libexpat
VERSION_EXIF=0.6.24         # https://github.com/libexif/libexif
VERSION_LCMS2=2.16          # https://github.com/mm2/Little-CMS
VERSION_HWY=1.2.0           # https://github.com/google/highway
VERSION_BROTLI=1.1.0        # https://github.com/google/brotli
VERSION_MOZJPEG=4.1.5       # https://github.com/mozilla/mozjpeg
VERSION_JXL=0.10.3          # https://github.com/libjxl/libjxl
VERSION_SPNG=0.7.4          # https://github.com/randy408/libspng
VERSION_IMAGEQUANT=2.4.1    # https://github.com/lovell/libimagequant
VERSION_CGIF=0.4.1          # https://github.com/dloebl/cgif
VERSION_WEBP=1.4.0          # https://chromium.googlesource.com/webm/libwebp
VERSION_TIFF=4.6.0          # https://gitlab.com/libtiff/libtiff
VERSION_RESVG=0.43.0        # https://github.com/RazrFalcon/resvg
VERSION_AOM=3.9.1           # https://aomedia.googlesource.com/aom
VERSION_HEIF=1.18.2         # https://github.com/strukturag/libheif
VERSION_VIPS=8.15.3         # https://github.com/libvips/libvips

VERSION_EMSCRIPTEN="$(emcc -dumpversion)"

# Generate versions.json
( printf "{\n"; \
  [ -n "$DISABLE_AVIF" ] || printf "  \"aom\": \"${VERSION_AOM}\",\n"; \
  [ -n "$DISABLE_JXL" ] || printf "  \"brotli\": \"${VERSION_BROTLI}\",\n"; \
  printf "  \"cgif\": \"${VERSION_CGIF}\",\n"; \
  printf "  \"emscripten\": \"${VERSION_EMSCRIPTEN}\",\n"; \
  printf "  \"exif\": \"${VERSION_EXIF}\",\n"; \
  printf "  \"expat\": \"${VERSION_EXPAT}\",\n"; \
  printf "  \"ffi\": \"${VERSION_FFI}\",\n"; \
  printf "  \"glib\": \"${VERSION_GLIB}\",\n"; \
  [ -n "$DISABLE_AVIF" ] || printf "  \"heif\": \"${VERSION_HEIF}\",\n"; \
  [[ -n "$DISABLE_SIMD" && -n "$DISABLE_JXL" ]] || printf "  \"highway\": \"${VERSION_HWY}\",\n"; \
  printf "  \"imagequant\": \"${VERSION_IMAGEQUANT}\",\n"; \
  [ -n "$DISABLE_JXL" ] || printf "  \"jxl\": \"${VERSION_JXL}\",\n"; \
  printf "  \"lcms\": \"${VERSION_LCMS2}\",\n"; \
  printf "  \"mozjpeg\": \"${VERSION_MOZJPEG}\",\n"; \
  [ -n "$DISABLE_SVG" ] || printf "  \"resvg\": \"${VERSION_RESVG}\",\n"; \
  printf "  \"spng\": \"${VERSION_SPNG}\",\n"; \
  printf "  \"tiff\": \"${VERSION_TIFF}\",\n"; \
  printf "  \"vips\": \"${VERSION_VIPS}\",\n"; \
  printf "  \"webp\": \"${VERSION_WEBP}\",\n"; \
  printf "  \"zlib-ng\": \"${VERSION_ZLIB_NG}\"\n"; \
  printf '}'; ) \
>$TARGET/versions.json

# Remove patch version component
without_patch() {
  echo "${1%.[[:digit:]]*}"
}

# Remove prerelease suffix
without_prerelease() {
  echo "${1%-[[:alnum:]]*}"
}

title() {
  echo -ne "\e]0;$1\a"
}

stage() {
  title "$1"
  echo -e "\e[1;32m============================================="
  echo "$1"
  echo -e "=============================================\e[0m"
}

stage "Environment"
emcc --version
node --version

[ -f "$TARGET/lib/pkgconfig/zlib.pc" ] || (
  stage "Compiling zlib-ng"
  mkdir $DEPS/zlib-ng
  curl -Ls https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$VERSION_ZLIB_NG.tar.gz | tar xzC $DEPS/zlib-ng --strip-components=1
  cd $DEPS/zlib-ng
  # SSE intrinsics needs to be checked for wasm32
  sed -i 's/BASEARCH_X86_FOUND/& OR BASEARCH_WASM32_FOUND/g' CMakeLists.txt
  emcmake cmake -B_build -H. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$TARGET -DBUILD_SHARED_LIBS=FALSE \
    ${DISABLE_SIMD:+-DWITH_OPTIM=FALSE} ${ENABLE_SIMD:+-DFORCE_SSE2=TRUE} -DWITH_RUNTIME_CPU_DETECTION=FALSE -DZLIB_COMPAT=TRUE \
    -DZLIB_ENABLE_TESTS=FALSE -DZLIBNG_ENABLE_TESTS=FALSE -DWITH_GTEST=FALSE
  make -C _build install
)

[ -f "$TARGET/lib/pkgconfig/libffi.pc" ] || (
  stage "Compiling ffi"
  mkdir $DEPS/ffi
  curl -Ls https://github.com/libffi/libffi/releases/download/v$VERSION_FFI/libffi-$VERSION_FFI.tar.gz | tar xzC $DEPS/ffi --strip-components=1
  cd $DEPS/ffi
  # TODO(kleisauke): Discuss this patch upstream
  curl -Ls https://github.com/libffi/libffi/compare/v$VERSION_FFI...kleisauke:cleanup${ENABLE_WASM_BIGINT:+-bigint}.patch | patch -p1
  # Compile without -fexceptions
  sed -i 's/ -fexceptions//g' configure
  emconfigure ./configure --host=$CHOST --prefix=$TARGET --enable-static --disable-shared --disable-dependency-tracking \
    --disable-builddir --disable-multi-os-directory --disable-raw-api --disable-structs --disable-docs
  make install
)

[ -f "$TARGET/lib/pkgconfig/glib-2.0.pc" ] || (
  stage "Compiling glib"
  mkdir $DEPS/glib
  curl -Lks https://download.gnome.org/sources/glib/$(without_patch $VERSION_GLIB)/glib-$VERSION_GLIB.tar.xz | tar xJC $DEPS/glib --strip-components=1
  cd $DEPS/glib
  # TODO(kleisauke): Discuss these patches upstream
  curl -Ls https://github.com/GNOME/glib/compare/$VERSION_GLIB...kleisauke:wasm-vips-$VERSION_GLIB.patch | patch -p1
  meson setup _build --prefix=$TARGET --cross-file=$MESON_CROSS --default-library=static --buildtype=release \
    --force-fallback-for=gvdb -Dintrospection=disabled -Dselinux=disabled -Dxattr=false -Dlibmount=disabled -Dsysprof=disabled -Dnls=disabled \
    -Dtests=false -Dglib_assert=false -Dglib_checks=false
  meson install -C _build --tag devel
)

[ -f "$TARGET/lib/pkgconfig/expat.pc" ] || (
  stage "Compiling expat"
  mkdir $DEPS/expat
  curl -Ls https://github.com/libexpat/libexpat/releases/download/R_${VERSION_EXPAT//./_}/expat-$VERSION_EXPAT.tar.xz | tar xJC $DEPS/expat --strip-components=1
  cd $DEPS/expat
  emconfigure ./configure --host=$CHOST --prefix=$TARGET --enable-static --disable-shared --disable-dependency-tracking \
    --without-xmlwf --without-docbook --without-getrandom --without-sys-getrandom --without-examples --without-tests
  make install dist_cmake_DATA= nodist_cmake_DATA=
)

[ -f "$TARGET/lib/pkgconfig/libexif.pc" ] || (
  stage "Compiling exif"
  mkdir $DEPS/exif
  curl -Ls https://github.com/libexif/libexif/releases/download/v$VERSION_EXIF/libexif-$VERSION_EXIF.tar.bz2 | tar xjC $DEPS/exif --strip-components=1
  cd $DEPS/exif
  emconfigure ./configure --host=$CHOST --prefix=$TARGET --enable-static --disable-shared --disable-dependency-tracking \
    --disable-docs --disable-nls --without-libiconv-prefix --without-libintl-prefix CPPFLAGS="-DNO_VERBOSE_TAG_DATA"
  make install doc_DATA=
)

[ -f "$TARGET/lib/pkgconfig/lcms2.pc" ] || (
  stage "Compiling lcms2"
  mkdir $DEPS/lcms2
  curl -Ls https://github.com/mm2/Little-CMS/releases/download/lcms$VERSION_LCMS2/lcms2-$VERSION_LCMS2.tar.gz | tar xzC $DEPS/lcms2 --strip-components=1
  cd $DEPS/lcms2
  meson setup _build --prefix=$TARGET --cross-file=$MESON_CROSS --default-library=static --buildtype=release \
    -Djpeg=disabled -Dtiff=disabled
  meson install -C _build --tag devel
)

[ -f "$TARGET/lib/pkgconfig/libhwy.pc" ] || [[ -n "$DISABLE_SIMD" && -n "$DISABLE_JXL" ]] || (
  stage "Compiling hwy"
  mkdir $DEPS/hwy
  curl -Ls https://github.com/google/highway/archive/refs/tags/$VERSION_HWY.tar.gz | tar xzC $DEPS/hwy --strip-components=1
  cd $DEPS/hwy
  # Remove build path from binary
  sed -i 's/HWY_ASSERT/HWY_DASSERT/' hwy/aligned_allocator.cc
  emcmake cmake -B_build -H. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$TARGET -DBUILD_SHARED_LIBS=FALSE \
    -DBUILD_TESTING=FALSE -DHWY_ENABLE_CONTRIB=FALSE -DHWY_ENABLE_EXAMPLES=FALSE -DHWY_ENABLE_TESTS=FALSE
  make -C _build install
)

[ -f "$TARGET/lib/pkgconfig/libbrotlicommon.pc" ] || [ -n "$DISABLE_JXL" ] || (
  stage "Compiling brotli"
  mkdir $DEPS/brotli
  curl -Ls https://github.com/google/brotli/archive/refs/tags/v$VERSION_BROTLI.tar.gz | tar xzC $DEPS/brotli --strip-components=1
  cd $DEPS/brotli
  # Exclude internal dictionary, see: https://github.com/emscripten-core/emscripten/issues/9960
  emcmake cmake -B_build -H. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$TARGET -DBROTLI_DISABLE_TESTS=TRUE \
    -DCMAKE_C_FLAGS="$CFLAGS -DBROTLI_EXTERNAL_DICTIONARY_DATA"
  make -C _build install
)

[ -f "$TARGET/lib/pkgconfig/libjpeg.pc" ] || (
  stage "Compiling jpeg"
  mkdir $DEPS/jpeg
  curl -Ls https://github.com/mozilla/mozjpeg/archive/refs/tags/v$VERSION_MOZJPEG.tar.gz | tar xzC $DEPS/jpeg --strip-components=1
  cd $DEPS/jpeg
  # Compile without SIMD support, see: https://github.com/libjpeg-turbo/libjpeg-turbo/issues/250
  # Disable environment variables usage, see: https://github.com/libjpeg-turbo/libjpeg-turbo/issues/600
  emcmake cmake -B_build -H. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$TARGET -DENABLE_STATIC=TRUE \
    -DENABLE_SHARED=FALSE -DWITH_JPEG8=TRUE -DWITH_SIMD=FALSE -DWITH_TURBOJPEG=FALSE -DPNG_SUPPORTED=FALSE \
    -DCMAKE_C_FLAGS="$CFLAGS -DNO_GETENV -DNO_PUTENV"
  make -C _build install
)


[ -f "$TARGET/lib/pkgconfig/spng.pc" ] || (
  stage "Compiling spng"
  mkdir $DEPS/spng
  curl -Ls https://github.com/randy408/libspng/archive/refs/tags/v$VERSION_SPNG.tar.gz | tar xzC $DEPS/spng --strip-components=1
  cd $DEPS/spng
  # TODO(kleisauke): Discuss this patch upstream
  curl -Ls https://github.com/randy408/libspng/compare/v$VERSION_SPNG...kleisauke:wasm-vips.patch | patch -p1
  # Switch the default zlib compression strategy to Z_RLE, as this is especially suitable for PNG images
  sed -i 's/Z_FILTERED/Z_RLE/g' spng/spng.c
  meson setup _build --prefix=$TARGET --cross-file=$MESON_CROSS --default-library=static --buildtype=release \
    -Dbuild_examples=false -Dstatic_zlib=true ${DISABLE_SIMD:+-Denable_opt=false} ${ENABLE_SIMD:+-Dc_args="$CFLAGS -msse4.1 -DSPNG_SSE=4"}
  meson install -C _build --tag devel
)

[ -f "$TARGET/lib/pkgconfig/imagequant.pc" ] || (
  stage "Compiling imagequant"
  mkdir $DEPS/imagequant
  curl -Ls https://github.com/lovell/libimagequant/archive/refs/tags/v$VERSION_IMAGEQUANT.tar.gz | tar xzC $DEPS/imagequant --strip-components=1
  cd $DEPS/imagequant
  meson setup _build --prefix=$TARGET --cross-file=$MESON_CROSS --default-library=static --buildtype=release \
    ${ENABLE_SIMD:+-Dc_args="$CFLAGS -msse -DUSE_SSE=1"}
  meson install -C _build --tag devel
)

[ -f "$TARGET/lib/pkgconfig/libwebp.pc" ] || (
  stage "Compiling webp"
  mkdir $DEPS/webp
  curl -Ls https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$VERSION_WEBP.tar.gz | tar xzC $DEPS/webp --strip-components=1
  cd $DEPS/webp
  # Prepend `-msimd128` to SSE flags, see: https://github.com/emscripten-core/emscripten/issues/12714
  sed -i 's/-msse/-msimd128 &/g' configure
  # Disable threading support, we rely on libvips' thread pool
  emconfigure ./configure --host=$CHOST --prefix=$TARGET --enable-static --disable-shared --disable-dependency-tracking \
    ${DISABLE_SIMD:+--disable-sse2 --disable-sse4.1} ${ENABLE_SIMD:+--enable-sse2 --enable-sse4.1} --disable-neon \
    --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-threading \
    --enable-libwebpmux --enable-libwebpdemux CPPFLAGS="-DWEBP_DISABLE_STATS -DWEBP_REDUCE_CSP"
  make install bin_PROGRAMS= noinst_PROGRAMS= man_MANS=
)


[ -f "$TARGET/lib/pkgconfig/vips.pc" ] || (
  stage "Compiling vips"
  mkdir $DEPS/vips
  curl -Ls https://github.com/libvips/libvips/releases/download/v$VERSION_VIPS/vips-$(without_prerelease $VERSION_VIPS).tar.xz | tar xJC $DEPS/vips --strip-components=1
  cd $DEPS/vips
  # Emscripten specific patches
  curl -Ls https://github.com/libvips/libvips/compare/v$VERSION_VIPS...kleisauke:wasm-vips-8.15.patch | patch -p1
  # Disable HBR support in heifsave
  curl -Ls https://github.com/libvips/build-win64-mxe/raw/v$VERSION_VIPS/build/patches/vips-8-heifsave-disable-hbr-support.patch | patch -p1
  # Disable building man pages, gettext po files, tools, and (fuzz-)tests
  sed -i "/subdir('man')/{N;N;N;N;d;}" meson.build
  meson setup _build --prefix=$TARGET --cross-file=$MESON_CROSS --default-library=static --buildtype=release \
    -Ddeprecated=false -Dexamples=false -Dcplusplus=$LIBVIPS_CPP -Dauto_features=disabled \
    -Dexif=enabled -Dwebp=enabled \
    -Dimagequant=enabled -Djpeg=enabled \
    -Dlcms=enabled ${ENABLE_SIMD:+-Dhighway=enabled} \
    -Dspng=enabled -Dnsgif=false -Dppm=false -Danalyze=false \
    -Dradiance=false
  meson install -C _build --tag runtime,devel
  # Emscripten requires linking to side modules to find the necessary symbols to export
  module_dir=$(printf '%s\n' $TARGET/lib/vips-modules-* | sort -n | tail -1)
  [ -d "$module_dir" ] && modules=$(find $module_dir/ -type f -printf " %p") || true
  sed -i "/^Libs:/ s/$/${modules//\//\\/}/" $TARGET/lib/pkgconfig/vips.pc
)

[ -n "$DISABLE_BINDINGS" ] || (
  stage "Compiling JS bindings"
  mkdir $DEPS/wasm-vips
  cd $DEPS/wasm-vips
  emcmake cmake $SOURCE_DIR -DCMAKE_BUILD_TYPE=Release -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$SOURCE_DIR/lib" \
    -DENVIRONMENT=${ENVIRONMENT//,/;} -DENABLE_MODULES=$MODULES -DENABLE_WASMFS=$WASM_FS
  make
)

[ -n "$DISABLE_BINDINGS" ] || [ "$ENVIRONMENT" != "web,node" ] || (
  # Building for both Node.js and web, prepare NPM package
  stage "Prepare NPM package"

  # The produced binary should be the same across the different variants (sanity check)
  expected_sha256=$(sha256sum "$SOURCE_DIR/lib/vips.wasm" | awk '{ print $1 }')
  for file in vips-es6.wasm vips-node.wasm vips-node-es6.wasm; do
    echo "$expected_sha256 $SOURCE_DIR/lib/$file" | sha256sum --check --quiet
    rm $SOURCE_DIR/lib/$file
  done

  # Use a single wasm binary for web and Node.js
  for file in vips-es6.js vips-node.js vips-node-es6.mjs; do
    sed -i "s/${file%.*}.wasm/vips.wasm/g" $SOURCE_DIR/lib/$file
  done

  # Omit -es6 suffix from Node.js files
  mv $SOURCE_DIR/lib/vips-node-es6.mjs $SOURCE_DIR/lib/vips-node.mjs
  sed -i 's/vips-node-es6/vips-node/g' $SOURCE_DIR/lib/vips-node.mjs

  # Print the target features section
  echo -n "Used Wasm features: "
  $EMSDK/upstream/bin/wasm-opt --mvp-features --print-features -o /dev/null $SOURCE_DIR/lib/vips.wasm | \
    sed 's/^--enable-//' | paste -sd' '

  # Copy dynamic loadable modules
  module_dir=$(printf '%s\n' $TARGET/lib/vips-modules-* | sort -n | tail -1)
  [ -d "$module_dir" ] && cp $module_dir/* $SOURCE_DIR/lib || true

  # Copy versions.json
  cp $TARGET/versions.json $SOURCE_DIR
)
