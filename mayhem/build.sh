#!/usr/bin/env bash
#
# mayhem/build.sh — build the kubevirt `fuzz_admitter` harness as a sanitized
# libFuzzer binary (native-Go libFuzzer path: `go build -buildmode=c-archive`
# with the compiler's `-d=libfuzzer` coverage instrumentation, then link the
# archive with clang -fsanitize=fuzzer,address). Also builds a standalone
# run-once reproducer and the upstream unit-test packages (for mayhem/test.sh).
#
# Runs inside the commit image (GO mayhem/Dockerfile) as `mayhem` in /mayhem.
# GOROOT/GOPATH/GOMODCACHE are pinned by the Dockerfile ENV under /opt/toolchains
# (absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - kubevirt vendors ALL its dependencies (vendor/ + go.work), so we build with
#     -mod=vendor: nothing is fetched from the network on the first build OR the
#     offline re-run. A file-proxy GOPROXY is still exported as a belt-and-braces
#     fallback for any tool that ignores -mod=vendor.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASan-only for the libFuzzer link (keep ASan regardless of base default).
: "${SANITIZER_FLAGS=-fsanitize=address}"
# Debug-info contract (SPEC §6.2 item 10): DWARF < 4. The cgo C shim + the final
# clang link land the first CU; -gdwarf-3 keeps it < 4 so triage can read it.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS GO_DEBUG_FLAGS MAYHEM_JOBS

# Resolve modules from the vendored tree; file-proxy fallback stays offline-first.
export GOFLAGS="-mod=vendor -buildvcs=false"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
# kubevirt builds with the `selinux` build tag (hack/common.sh default).
export GO_BUILD_TAGS="${GO_BUILD_TAGS:-selinux}"
# The cgo C shim is compiled with $CC ($CGO_*FLAGS): thread the DWARF-3 flags in so
# the shim's compilation unit (which lands first in the linked ELF) is DWARF < 4.
export CGO_ENABLED=1
export CGO_CFLAGS="${CGO_CFLAGS:-} ${GO_DEBUG_FLAGS} -O1"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} ${GO_DEBUG_FLAGS} -O1"

SRC="${SRC:-/mayhem}"
cd "$SRC"
go version

TARGET="fuzz_admitter"
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

echo "=== building $TARGET (go build -buildmode=c-archive + -d=libfuzzer coverage) ==="
# -d=libfuzzer makes the Go compiler emit libFuzzer coverage counters over the
# fuzzed Go code (the same instrumentation OSS-Fuzz uses for native Go targets);
# -buildmode=c-archive exposes the //export LLVMFuzzerTestOneInput entry point.
# Instrument only kubevirt's own packages (the code under test): `all=` would
# also counter-instrument the entire vendored k8s tree + stdlib (~440k edges),
# which makes process startup take minutes and trips Mayhem's sanity check.
go build -tags "$GO_BUILD_TAGS,libfuzzer,gofuzz" \
  -gcflags "kubevirt.io/kubevirt/...=-d=libfuzzer" \
  -buildmode=c-archive \
  -o "$BUILD/$TARGET.a" ./mayhem/harness/
# Link the archive into a libFuzzer binary (ASan + fuzzer driver).
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
  "$BUILD/$TARGET.a" -lpthread -lresolv -ldl -o "/mayhem/$TARGET"
echo "built /mayhem/$TARGET"

# Standalone (non-fuzzer) run-once reproducer over the SAME harness archive: link
# without -fsanitize=fuzzer and provide a tiny main() that feeds one input file to
# LLVMFuzzerTestOneInput. Repro artifact, not a Mayhemfile target.
echo "=== building ${TARGET}-standalone ==="
cat > "$BUILD/standalone_main.c" <<'EOF'
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef __cplusplus
extern "C"
#endif
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int main(int argc, char **argv) {
  if (argc < 2) return 0;
  FILE *f = fopen(argv[1], "rb");
  if (!f) return 0;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n < 0) { fclose(f); return 0; }
  uint8_t *buf = (uint8_t *)malloc((size_t)n + 1);
  size_t rd = fread(buf, 1, (size_t)n, f);
  fclose(f);
  LLVMFuzzerTestOneInput(buf, rd);
  free(buf);
  return 0;
}
EOF
$CXX $SANITIZER_FLAGS $GO_DEBUG_FLAGS \
  "$BUILD/standalone_main.c" "$BUILD/$TARGET.a" -lpthread -lresolv -ldl \
  -o "/mayhem/${TARGET}-standalone"
echo "built /mayhem/${TARGET}-standalone"

# Pre-compile the ENTIRE upstream unit-test dependency graph (upstream's
# `make go-test` set: ./cmd/... ./pkg/...) into the pinned GOCACHE, with the
# project's normal flags (no sanitizer/fuzzer instrumentation). Pre-building
# every .test binary is not viable for kubevirt (hundreds of ~150MB static
# binaries), so mayhem/test.sh's `go test` resolves from this warm cache —
# vendored deps, no network. -run '^$' compiles everything but runs no tests.
echo "=== compiling upstream unit-test packages (cache warm) ==="
# cgo with gcc here (and in mayhem/test.sh), like upstream's builder: clang's cgo
# constant extraction turns the KVM _IOC ioctl macros in virt-handler/node-labeller
# into negative ints ("constant overflows uintptr").
export CC=gcc CXX=g++ CGO_CFLAGS= CGO_CXXFLAGS=
# fake-qemu-process: test helper binary the pkg/virt-launcher monitor tests exec
# (upstream's build pipeline places it under _out/ before the unit-test lane).
go build -tags "$GO_BUILD_TAGS" -o _out/cmd/fake-qemu-process/fake-qemu-process ./cmd/fake-qemu-process
# cmd/container-disk-v2alpha is C-only; upstream ignores it in the unit-test lane.
# (assignment swallows go list's nonzero exit on that known-bad package under set -e)
UNIT_PKGS="$(go list -e -tags "$GO_BUILD_TAGS" ./cmd/... ./pkg/... | grep -v 'cmd/container-disk-v2alpha')"
go test -tags "$GO_BUILD_TAGS" -skip FuzzAdmitter -run '^$' -count=1 $UNIT_PKGS > /dev/null
echo "build.sh complete"
