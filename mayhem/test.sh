#!/usr/bin/env bash
#
# mayhem/test.sh — RUN kubevirt's OWN upstream unit-test suite and report CTRF.
#
# Mirrors upstream's `make go-test` (hack/build-go.sh test): the full unit suite
# over ./cmd/... and ./pkg/... with the `selinux` build tag, skipping the
# FuzzAdmitter native fuzz test exactly as upstream does ("Skip fuzz tests, as
# they are not part of regular unit testing"). The functional/e2e suite under
# tests/ requires a live Kubernetes cluster and is not runnable in the commit
# image (skipped, as in upstream's own unit-test lane).
#
# mayhem/build.sh pre-compiles the test dependency graph into the pinned GOCACHE,
# so the `go test` below resolves from the cache (vendored deps; no network).
# These are upstream's real assertion suites (Ginkgo/gomega + go test): they
# assert behavior/output, so a neutered binary or no-op patch fails them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
SRC="${SRC:-/mayhem}"
cd "$SRC"

export GOFLAGS="-mod=vendor -buildvcs=false"
export GO_BUILD_TAGS="${GO_BUILD_TAGS:-selinux}"
# gcc for cgo, like upstream's builder (clang mis-extracts the KVM _IOC constants
# in virt-handler/node-labeller); matches the build.sh cache-warm compile.
export CC=gcc CXX=g++ CGO_CFLAGS= CGO_CXXFLAGS=
# Dynamically-linked test binaries (external linking): Go's default internal
# linking produces static executables that dynamic-instrumentation harnesses
# (LD_PRELOAD-based) can't see; kubevirt's cgo packages link externally anyway.
export CGO_ENABLED=1

LOG="${TMPDIR:-/tmp}/kubevirt-gotest.json"

# Version ldflags, exactly as upstream's test lane (hack/build-go.sh): virtctl's
# version tests assert on this metadata.
export KUBEVIRT_DIR="$SRC"
source hack/version.sh
LDFLAGS="$(kubevirt::version::ldflags)"

# cmd/container-disk-v2alpha is a C-only package upstream explicitly ignores in
# its unit-test lane (--ignore=container-disk-v2alpha).
PKGS="$(go list -e -tags "$GO_BUILD_TAGS" ./cmd/... ./pkg/... | grep -v 'cmd/container-disk-v2alpha')"

# Upstream unit-test invocation (hack/build-go.sh test), with -json for counting.
# -count=1: always execute the test binaries — never replay Go's test cache.
go test -tags "$GO_BUILD_TAGS" -ldflags "$LDFLAGS -linkmode=external" -skip FuzzAdmitter -count=1 -timeout 15m -json \
  $PKGS > "$LOG" 2>"${TMPDIR:-/tmp}/kubevirt-gotest.err" || true

read -r passed failed skipped < <(python3 - "$LOG" <<'PY'
import json, sys
passed = failed = skipped = 0
pkg_fail = set()
pkg_test_fail = set()
with open(sys.argv[1]) as fh:
    for line in fh:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        act = ev.get("Action")
        if ev.get("Test"):
            if act == "pass":
                passed += 1
            elif act == "fail":
                failed += 1
                pkg_test_fail.add(ev.get("Package"))
            elif act == "skip":
                skipped += 1
        elif act == "fail":
            pkg_fail.add(ev.get("Package"))
# A package-level failure with no failing test = build/setup error: count it as a failure.
failed += len(pkg_fail - pkg_test_fail)
print(passed, failed, skipped)
PY
)

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Sanity: the suite must actually have run (thousands of upstream tests).
if [ "$passed" -eq 0 ]; then
  echo "ERROR: no passing tests recorded — suite did not run (build.sh bug or toolchain missing)" >&2
  grep -m5 . "${TMPDIR:-/tmp}/kubevirt-gotest.err" >&2 || true
  emit_ctrf "go-test" 0 1 0
  exit 1
fi

emit_ctrf "go-test" "$passed" "$failed" "$skipped"
