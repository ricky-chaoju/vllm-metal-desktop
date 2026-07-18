#!/usr/bin/env bash
#
# M0 technical gate (docs/PLAN.md §8, risk #1).
#
# Proves the load-the-foreign-engine-dylib question that the whole subprocess
# architecture rests on, using three codesigned permutations of a tiny loader +
# a tiny ad-hoc-signed (no Team ID) dylib that stands in for _paged_ops.so /
# libmlx.dylib:
#
#   A  ad-hoc loader                         -> models the spawned venv python
#   B  hardened runtime + disable-lib-valid. -> models the app hosting in-process
#   C  hardened runtime, library validation  -> NEGATIVE CONTROL (no DLV)
#
# Expected: A and B load the foreign dylib; C is blocked (proving that
# `com.apple.security.cs.disable-library-validation` is precisely the gate).
#
# Note: the real architecture is case A — the app spawns the venv python, which
# is its own (ad-hoc / third-party-signed) process and is not subject to this
# app's code-signing flags. Case B validates our defensive entitlement choice
# for any future in-process helper.

set -uo pipefail
cd "$(dirname "$0")"

BUILD=build
rm -rf "$BUILD"; mkdir -p "$BUILD"

fatal() { echo "FATAL: $*" >&2; exit 3; }

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
[ -n "${IDENTITY:-}" ] || fatal "no codesigning identity found"
echo "Signing identity: $IDENTITY"

clang -arch arm64 -dynamiclib -o "$BUILD/libpoc.dylib" poc.c || fatal "dylib build failed"
clang -arch arm64 -o "$BUILD/loader" loader.c              || fatal "loader build failed"

# Make the dylib "foreign": ad-hoc signature, no Team ID.
codesign -f -s - "$BUILD/libpoc.dylib" || fatal "dylib ad-hoc sign failed"

mk() { cp "$BUILD/loader" "$BUILD/$1"; }
mk loader_adhoc; codesign -f -s - "$BUILD/loader_adhoc"                                              || fatal "A sign failed"
mk loader_dlv;   codesign -f -o runtime --entitlements dlv.entitlements -s "$IDENTITY" "$BUILD/loader_dlv" || fatal "B sign failed"
mk loader_lv;    codesign -f -o runtime -s "$IDENTITY" "$BUILD/loader_lv"                            || fatal "C sign failed"

# Hardened programs reject dlopen() of a *relative* path, so always pass an
# absolute one (the real engine paths under ~/.venv-vllm-metal are absolute too).
DYLIB_ABS="$PWD/$BUILD/libpoc.dylib"

run() {  # $1=label  $2=binary
    LAST_OUT=$("$BUILD/$2" "$DYLIB_ABS" 2>&1)
    LAST_RC=$?
    printf '[%-44s] rc=%s :: %s\n' "$1" "$LAST_RC" "$LAST_OUT"
}

echo; echo "=== Results ==="
PASS=1

run "A ad-hoc loader (subprocess model)" loader_adhoc
if [ "$LAST_RC" -eq 0 ]; then echo "  PASS  loaded foreign dylib (expected)"; else echo "  FAIL  could not load (UNEXPECTED)"; PASS=0; fi

run "B hardened + disable-library-validation" loader_dlv
if [ "$LAST_RC" -eq 0 ]; then echo "  PASS  loaded foreign dylib (expected)"; else echo "  FAIL  could not load (UNEXPECTED)"; PASS=0; fi

run "C hardened + library-validation ON (control)" loader_lv
if [ "$LAST_RC" -ne 0 ]; then echo "  PASS  blocked foreign dylib (expected — DLV is the gate)"; else echo "  NOTE  loaded anyway (library validation not enforced here)"; fi

echo
if [ "$PASS" -eq 1 ]; then
    echo "GATE PASS — the subprocess model loads the engine's foreign dylibs; the hardened+DLV path works too."
    exit 0
else
    echo "GATE FAIL — a positive case failed to load the foreign dylib; revisit the architecture."
    exit 1
fi
