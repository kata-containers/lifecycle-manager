# Copyright (c) 2026 The Kata Containers Authors
# SPDX-License-Identifier: Apache-2.0

# Alpine-based image with Helm 4, kubectl, and jq for all Argo workflow steps.
# Built weekly for security updates; used by kata-lifecycle-manager workflow.

ARG ALPINE_VERSION=3.21
FROM alpine:${ALPINE_VERSION}

# Install shell tools and jq; then Helm 4 and kubectl
# hadolint ignore=DL3018
RUN apk add --no-cache bash curl ca-certificates openssl tar jq && \
    export USE_SUDO=false && \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash && \
    helm version && \
    ARCH=$(uname -m) && \
    case "${ARCH}" in \
        x86_64)  KUBECTL_ARCH=amd64 ;; \
        aarch64) KUBECTL_ARCH=arm64 ;; \
        ppc64le) KUBECTL_ARCH=ppc64le ;; \
        s390x)   KUBECTL_ARCH=s390x ;; \
        *)       echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt) && \
    curl -fL --progress-bar -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl && \
    kubectl version --client

CMD ["/bin/bash"]
