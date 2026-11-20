# Syntax: https://docs.docker.com/engine/reference/builder/
ARG ARGOCD_VERSION=v3.5.6

# Use official ArgoCD image as base
FROM quay.io/argoproj/argocd:${ARGOCD_VERSION}

# Build arguments
ARG TRANSCRYPT_VERSION=v2.3.2

# Switch to root for installation
USER 0

# Install dependencies and transcrypt
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssl \
        git \
        ca-certificates \
        curl \
        bsdextrautils \
        xxd && \
    # Install transcrypt
    curl -fsSLo /usr/local/bin/transcrypt \
        "https://raw.githubusercontent.com/elasticdog/transcrypt/${TRANSCRYPT_VERSION}/transcrypt" && \
    chmod +x /usr/local/bin/transcrypt && \
    # Verify transcrypt installation and dependencies
    transcrypt --version && \
    command -v column && \
    command -v hexdump && \
    command -v xxd && \
    # Cleanup
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copy git wrapper
COPY git-wrapper.sh /usr/local/bin/git-wrapper

# Set permissions and create git.real symlink
RUN chmod +x /usr/local/bin/git-wrapper && \
    # Backup original git binary
    mv /usr/bin/git /usr/bin/git.real && \
    # Replace with wrapper
    ln -s /usr/local/bin/git-wrapper /usr/bin/git

# Switch back to argocd user
USER 999

# Set environment variables
ENV TRANSCRYPT_CIPHER=aes-256-cbc

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["sh", "-c", "argocd version --client || exit 1"]

# Labels for metadata
LABEL maintainer="steled" \
      org.opencontainers.image.title="ArgoCD Transcrypt Plugin" \
      org.opencontainers.image.description="ArgoCD repo-server with transcrypt support" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/steled/argocd-transcrypt-plugin" \
      org.opencontainers.image.documentation="https://github.com/steled/argocd-transcrypt-plugin/blob/main/README.md"

# Keep the original entrypoint from ArgoCD base image
# This will be argocd-repo-server for the repo-server deployment
