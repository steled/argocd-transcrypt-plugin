#!/bin/bash
#
# Scenario executed INSIDE the plugin image / repo-server pod.
#
# 1. Creates a transcrypt-encrypted repository and publishes it as a local "remote".
# 2. Simulates what ArgoCD does (git init + fetch + checkout) through the git wrapper.
# 3. Prints "RESULT=<first line of the checked out secret file>".
#
# The password for the repository has to be available as /transcrypt-secret/_tmp_e2e-remote_remote
# (the secret key derived from file:///tmp/e2e-remote/remote.git).

set -eu

GIT_REAL=/usr/bin/git.real
PASSWORD='S3cret-pw'
BASE=/tmp/e2e-remote
export HOME=/tmp/e2e-home

rm -rf "$BASE" "$HOME" /tmp/e2e-work
mkdir -p "$BASE" "$HOME"

# Author an encrypted repository (bypassing the wrapper)
mkdir "$BASE/author"
cd "$BASE/author"
"$GIT_REAL" init -q -b main
"$GIT_REAL" config user.email "test@example.com"
"$GIT_REAL" config user.name "test"
transcrypt -c aes-256-cbc -p "$PASSWORD" -y >/dev/null 2>&1
echo '*.secret.yaml filter=crypt diff=crypt merge=crypt' > .gitattributes
echo 'password: hunter2' > values.secret.yaml
"$GIT_REAL" add -A
"$GIT_REAL" commit -q -m "init"
"$GIT_REAL" clone -q --bare "$BASE/author" "$BASE/remote.git"

# Simulate ArgoCD: fresh directory, init, fetch, checkout - all through the wrapper
mkdir /tmp/e2e-work
cd /tmp/e2e-work
git init -q -b main
git remote add origin "file://$BASE/remote.git"
git fetch -q origin 2>&1
git checkout -q -f origin/main 2>&1

echo "RESULT=$(head -n1 values.secret.yaml)"
