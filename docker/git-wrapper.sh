#!/bin/bash
#
# Git wrapper script for ArgoCD repo-server to automatically decrypt transcrypt files
# This script wraps the git command and runs transcrypt-init after certain git operations
#
# Usage: This script should replace /usr/bin/git in the PATH

set -euo pipefail

# Configuration
TRANSCRYPT_PASSWORD_DIR="${TRANSCRYPT_PASSWORD_DIR:-/transcrypt-secret}"
TRANSCRYPT_CIPHER="${TRANSCRYPT_CIPHER:-aes-256-cbc}"
REAL_GIT="/usr/bin/git.real"

# Logging to stderr and to argocd logs
log() {
    # Log to both stderr and a format that ArgoCD captures
    echo "[git-wrapper] $*" >&2
    echo "time=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" level=info msg=\"[git-wrapper] $*\"" >&1
}

# Execute the real git command
"$REAL_GIT" "$@"
GIT_EXIT_CODE=$?

# If git command failed, exit with the same code
if [ $GIT_EXIT_CODE -ne 0 ]; then
    exit $GIT_EXIT_CODE
fi

# Check if this was a checkout or clone command
case "${1:-}" in
    checkout|clone|pull|fetch)
        log "Git command: $1, checking for transcrypt configuration"
        
        # Check if transcrypt is already configured using transcrypt --display
        if transcrypt --display >/dev/null 2>&1; then
            log "Transcrypt already configured; skipping init."
        else
            log "Transcrypt not configured, attempting initialization..."
            
            # Get repository-specific password
            REPO_URL=$("$REAL_GIT" config --get remote.origin.url 2>/dev/null || echo "")
            
            if [ -z "$REPO_URL" ]; then
                log "Could not determine repository URL, skipping transcrypt"
                exit 0
            fi
            
            # Never log credentials that might be embedded in the remote URL (https://user:token@host/...)
            log "Repository URL: ${REPO_URL//\/\/*@/\/\/***@}"
            # Documented key format (see docs/MULTI-REPO.md): protocol/user removed, ':' and '/' -> '_'
            REPO_KEY=$(echo "$REPO_URL" | sed -e 's|.*://||' -e 's|^[^@/]*@||' -e 's|[:/]|_|g' -e 's|\.git$||' | tr '[:upper:]' '[:lower:]')
            
            # Load the repository-specific password (no default password: repositories
            # without a matching key are left untouched)
            REPO_PASSWORD_FILE="${TRANSCRYPT_PASSWORD_DIR}/${REPO_KEY}"

            if [ ! -f "$REPO_PASSWORD_FILE" ]; then
                log "No repository-specific password found (key: $REPO_KEY), repository does not use transcrypt"
                exit 0
            fi

            log "Found repository-specific password for: $REPO_KEY, loading"
            TRANSCRYPT_PASSWORD=$(cat "$REPO_PASSWORD_FILE")

            # Initial configuration (decrypts the defined files locally)
            TRANSCRYPT_EXIT=0
            TRANSCRYPT_OUTPUT=$(transcrypt -c "$TRANSCRYPT_CIPHER" -p "$TRANSCRYPT_PASSWORD" -y 2>&1) || TRANSCRYPT_EXIT=$?
            
            if [ $TRANSCRYPT_EXIT -eq 0 ]; then
                log "Transcrypt initialization successful"
            else
                # Force synchronous output of all error details
                {
                    echo "[git-wrapper] ====== TRANSCRYPT ERROR ======"
                    echo "[git-wrapper] Exit code: $TRANSCRYPT_EXIT"
                    echo "[git-wrapper] Cipher: $TRANSCRYPT_CIPHER"
                    echo "[git-wrapper] Repository key: $REPO_KEY"
                    echo "[git-wrapper] Password file: $REPO_PASSWORD_FILE"
                    echo "[git-wrapper] Working directory: $(pwd)"
                    echo "[git-wrapper] Transcrypt output:"
                    echo "$TRANSCRYPT_OUTPUT"
                    echo "[git-wrapper] =============================="
                } >&2
                
                exit 1
            fi
        fi
        ;;
esac

exit $GIT_EXIT_CODE
