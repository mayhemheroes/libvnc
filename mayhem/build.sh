#!/usr/bin/env bash
#
# libvnc/mayhem/build.sh — build LibVNC/libvncserver's OSS-Fuzz harness as a sanitized libFuzzer
# target (+ a standalone reproducer), AND libvncserver's own ctest suite for mayhem/test.sh.
#
# Fuzzed surface: the RFB SERVER message parser. fuzz_server.c (test/fuzz_server.c upstream) sets up
# an rfbScreen + a fake client, then loops rfbProcessClientMessage(cl), which parses attacker-
# controlled RFB client->server protocol bytes. The bytes are delivered to the server's socket-read
# path via the fuzz_data/fuzz_offset/fuzz_size globals that sockets.c defines under
# FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION — so the library MUST be compiled with that macro for the
# harness externs to resolve and for input to actually flow in.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC). We
# compile libvncserver ITSELF with $SANITIZER_FLAGS so the parser (not just the harness) is
# instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX MAYHEM_JOBS DEBUG_FLAGS

FUZZ_MACRO="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1"

cd "$SRC"
HARNESS_DIR="$SRC/mayhem/harnesses"

# ── 1) Build the libvncserver static lib + the fuzz_server target via CMake, sanitized ────────────
# WITH_TESTS=ON + LIB_FUZZING_ENGINE in env makes CMake emit the fuzz_server executable and link it
# against $LIB_FUZZING_ENGINE. FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION goes into CFLAGS so sockets.c
# compiles in the fuzz feed path + defines the fuzz_data externs the harness references.
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
# Unconditionally append fuzzer-no-link so libvncserver itself gets SanitizerCoverage
# instrumentation regardless of what SANITIZER_FLAGS the base image exports.  Without
# this the library compiles with ASan/UBSan but NO edge counters → 0 edges in Mayhem.
COVERAGE_FLAGS="-fsanitize=fuzzer-no-link"
LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
CC="$CC" CXX="$CXX" \
CFLAGS="$SANITIZER_FLAGS $COVERAGE_FLAGS $DEBUG_FLAGS $FUZZ_MACRO" \
CXXFLAGS="$SANITIZER_FLAGS $COVERAGE_FLAGS $DEBUG_FLAGS $FUZZ_MACRO" \
  cmake -S "$SRC" -B "$BUILD" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWITH_TESTS=ON \
    -DWITH_EXAMPLES=OFF \
    -DCMAKE_BUILD_TYPE=Plain
cmake --build "$BUILD" --target fuzz_server -j"$MAYHEM_JOBS"

cp "$BUILD/fuzz_server" /mayhem/fuzz_server
echo "built /mayhem/fuzz_server"

# ── 2) Standalone reproducer: relink the harness + standalone main against the sanitized static lib.
# Reuse the static vncserver lib + the libs CMake resolved (from its link.txt) so we match the
# build's dependency set without hardcoding it.
LIBVNC_A="$(find "$BUILD" -name 'libvncserver.a' | head -1)"
if [ -z "$LIBVNC_A" ]; then
  echo "ERROR: libvncserver.a not found under $BUILD" >&2; exit 1
fi
# Pull the exact dependency libs CMake used for fuzz_server (zlib/jpeg/png/lzo/ssl/crypto/...),
# straight from the recorded link command so we don't hardcode the optional-feature set. The libs
# are everything AFTER the fuzz_server.c .o token, minus libvncserver.a and the fuzzer engine flag
# (we re-supply our own lib + standalone main, no engine).
LINKTXT="$(find "$BUILD" -path '*fuzz_server.dir/link.txt' | head -1)"
EXTRA_LIBS=""
if [ -n "$LINKTXT" ]; then
  EXTRA_LIBS="$(tr ' ' '\n' < "$LINKTXT" \
    | grep -E '^(-l|/.*\.(so|a)$|-pthread$)' \
    | grep -vE 'libvncserver\.a$|fuzz_server' \
    | awk '!seen[$0]++' | tr '\n' ' ')"
fi
[ -n "$EXTRA_LIBS" ] || EXTRA_LIBS="-lz -lpthread -lm"
EXTRA_LIBS="$EXTRA_LIBS -lpthread -lm"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_MACRO \
    -I"$SRC/include" -I"$BUILD" -I"$BUILD/include" \
    "$HARNESS_DIR/fuzz_server.c" "$HARNESS_DIR/standalone_main.c" \
    "$LIBVNC_A" $EXTRA_LIBS \
    -o /mayhem/fuzz_server-standalone
echo "built /mayhem/fuzz_server-standalone (libs: $EXTRA_LIBS)"

# ── 3) Build libvncserver's OWN ctest suite with NORMAL flags (clean tree) so test.sh only RUNS it.
# No sanitizers, no fuzz macro: keeps test.sh an honest PATCH oracle (asserted/known-answer tests).
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  TESTBUILD="$SRC/mayhem-tests"
  rm -rf "$TESTBUILD"; mkdir -p "$TESTBUILD"
  env -u CFLAGS -u CXXFLAGS -u LIB_FUZZING_ENGINE \
    cmake -S "$SRC" -B "$TESTBUILD" \
      -DBUILD_SHARED_LIBS=OFF \
      -DWITH_TESTS=ON \
      -DWITH_EXAMPLES=OFF \
      -DCMAKE_BUILD_TYPE=Plain
  env -u CFLAGS -u CXXFLAGS -u LIB_FUZZING_ENGINE \
    cmake --build "$TESTBUILD" -j"$MAYHEM_JOBS"
  echo "built libvncserver ctest suite in mayhem-tests/"
else
  echo "SANITIZER_FLAGS empty (natural-crash build) — skipping the separate test-suite build" >&2
fi

echo "build.sh complete:"
ls -la /mayhem/fuzz_server /mayhem/fuzz_server-standalone 2>&1 || true
