#!/bin/bash
#
# Tests the git wrapper of the plugin image.
#
# Usage: tests/test-git-wrapper.sh [image]    (default: argocd-transcrypt-plugin:test)
#
# The image has to be built beforehand, e.g.
#   docker build -t argocd-transcrypt-plugin:test docker

set -uo pipefail

IMAGE="${1:-argocd-transcrypt-plugin:test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TOTAL=0
PASSED=0
FAILED=0

print_test() { TOTAL=$((TOTAL + 1)); echo -e "${YELLOW}[TEST]${NC} $1"; }
pass() { PASSED=$((PASSED + 1)); echo -e "${GREEN}[PASS]${NC} $1"; }
fail() {
    FAILED=$((FAILED + 1))
    echo -e "${RED}[FAIL]${NC} $1"
    if [ -n "${2:-}" ]; then
        while IFS= read -r line; do echo "    $line"; done <<< "$2"
    fi
}

# Run a command in the image with the given secret directory mounted
run_in_image() {
    local secret_dir="$1"
    shift
    docker run --rm \
        -v "${secret_dir}:/transcrypt-secret:ro" \
        -v "${SCRIPT_DIR}/encrypted-repo-scenario.sh:/scenario.sh:ro" \
        --entrypoint bash "$IMAGE" "$@" 2>&1
}

echo "======================================"
echo "Git Wrapper Tests (image: $IMAGE)"
echo "======================================"
echo

mkdir -p "$WORKDIR/secret-ok" "$WORKDIR/secret-empty" "$WORKDIR/secret-https"
chmod 755 "$WORKDIR" "$WORKDIR"/secret-*
printf 'S3cret-pw' > "$WORKDIR/secret-ok/_tmp_e2e-remote_remote"
printf 'unrelated' > "$WORKDIR/secret-https/github.com_myorg_my-repo"
chmod 644 "$WORKDIR"/secret-*/*

# Test 1: wrapper is installed
print_test "git is replaced by the wrapper"
OUT=$(run_in_image "$WORKDIR/secret-empty" -c 'readlink /usr/bin/git; test -x /usr/bin/git.real && echo real-git-present')
if echo "$OUT" | grep -q "git-wrapper" && echo "$OUT" | grep -q "real-git-present"; then
    pass "git is the wrapper and the real binary is kept as git.real"
else
    fail "wrapper not installed" "$OUT"
fi

# Test 2: files are decrypted when a matching password exists
print_test "Encrypted files are decrypted with the repository password"
OUT=$(run_in_image "$WORKDIR/secret-ok" /scenario.sh)
if echo "$OUT" | grep -q '^RESULT=password: hunter2$'; then
    pass "Files are decrypted after fetch/checkout"
else
    fail "files were not decrypted" "$OUT"
fi

# Test 3: repositories without a password are left untouched
print_test "Repositories without a password stay encrypted and do not fail"
OUT=$(run_in_image "$WORKDIR/secret-empty" /scenario.sh)
RC=$?
if [ $RC -eq 0 ] && echo "$OUT" | grep -q '^RESULT=U2FsdGVkX1' && echo "$OUT" | grep -q "does not use transcrypt"; then
    pass "Checkout succeeds, file remains encrypted"
else
    fail "unexpected behaviour without password (rc=$RC)" "$OUT"
fi

# Test 4: secret key derivation for https and ssh URLs
for URL in "https://github.com/MyOrg/My-Repo.git" "git@github.com:MyOrg/My-Repo.git"; do
    print_test "Secret key is derived from $URL"
    OUT=$(run_in_image "$WORKDIR/secret-https" -c "
        export HOME=/tmp/h; mkdir -p \$HOME /tmp/r && cd /tmp/r
        git init -q -b main
        git remote add origin '$URL'
        git commit -q --allow-empty -m x -c user.name=t -c user.email=t@e.c 2>/dev/null || true
        git checkout -q -b other
    ")
    if echo "$OUT" | grep -q "Found repository-specific password for: github.com_myorg_my-repo"; then
        pass "Key github.com_myorg_my-repo is used"
    else
        fail "wrong secret key derived" "$OUT"
    fi
done

# Test 5: credentials embedded in the remote URL are never logged
print_test "Credentials in the remote URL are not logged"
OUT=$(run_in_image "$WORKDIR/secret-https" -c "
    export HOME=/tmp/h; mkdir -p \$HOME /tmp/r && cd /tmp/r
    git init -q -b main
    git remote add origin 'https://user:T0kenValue@github.com/MyOrg/My-Repo.git'
    git checkout -q -b other
")
if echo "$OUT" | grep -q "Found repository-specific password for: github.com_myorg_my-repo" && ! echo "$OUT" | grep -q "T0kenValue"; then
    pass "Key is derived correctly and the token does not appear in the output"
else
    fail "credentials leaked or key wrong" "$OUT"
fi

echo
echo "======================================"
echo "Test Summary"
echo "======================================"
echo "Total tests run: $TOTAL"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "Failed: $FAILED"
echo "======================================"

[ "$FAILED" -eq 0 ]
