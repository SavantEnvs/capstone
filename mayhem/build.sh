#!/usr/bin/env bash
#
# mayhem/build.sh — builds the sanitized libcapstone + the fuzz_disasm harness (libFuzzer and standalone),
# and, with the project's NORMAL flags, cstool + cstest so mayhem/test.sh only has to run them.
# Re-runnable and offline: every dependency comes from the image (apt libyaml/libcyaml/cmocka).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The project, sanitized. Two static libs: one with libFuzzer coverage instrumentation for the fuzzer
#    binary, one without it for the standalone reproducer (which links no libFuzzer runtime).
build_lib() { # <dir> <extra flags>
  cmake -S "$SRC" -B "$SRC/$1" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $2" \
    -DCAPSTONE_BUILD_SHARED_LIBS=OFF -DCAPSTONE_BUILD_STATIC_LIBS=ON \
    -DCAPSTONE_BUILD_CSTOOL=OFF -DCAPSTONE_BUILD_LEGACY_TESTS=OFF -DCAPSTONE_BUILD_CSTEST=OFF \
    -DCAPSTONE_INSTALL=OFF
  cmake --build "$SRC/$1" -j"$MAYHEM_JOBS" --target capstone_static
}
build_lib build-fuzz "-fsanitize=fuzzer-no-link"
build_lib build-sa ""

# 2) fuzz_disasm (OSS-Fuzz's harness, from suite/fuzz): libFuzzer binary + standalone reproducer.
FUZZ_SRC=(suite/fuzz/fuzz_disasm.c suite/fuzz/platform.c)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-sa/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE \
    "${FUZZ_SRC[@]}" build-fuzz/lsan_off.o -Iinclude build-fuzz/libcapstone.a -o /mayhem/fuzz_disasm
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    "${FUZZ_SRC[@]}" build-sa/standalone_main.o build-fuzz/lsan_off.o -Iinclude build-sa/libcapstone.a \
    -o /mayhem/fuzz_disasm-standalone

# 3) The test suite, NORMAL flags: cstool + cstest (compiled directly: upstream's CMake would download
#    libyaml/libcyaml/cmocka at configure time).
cmake -S "$SRC" -B "$SRC/build-tests" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
  -DCAPSTONE_BUILD_SHARED_LIBS=OFF -DCAPSTONE_BUILD_STATIC_LIBS=ON \
  -DCAPSTONE_BUILD_CSTOOL=ON -DCAPSTONE_BUILD_LEGACY_TESTS=OFF -DCAPSTONE_BUILD_CSTEST=OFF \
  -DCAPSTONE_INSTALL=OFF
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target capstone_static cstool
$CC -O2 $COVERAGE_FLAGS -Iinclude -Isuite/cstest/include suite/cstest/src/*.c \
    build-tests/libcapstone.a -lcmocka -lcyaml -lyaml -lm -o build-tests/cstest
