#!/usr/bin/env bash
# Copyright (c) 2026 The Kata Containers Authors
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap a bare-metal Ubuntu 24.04 runner for kata-lifecycle-manager E2E tests.
# Run as root or with sudo.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root or with sudo."
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "Cannot determine OS: /etc/os-release not found."
    exit 1
fi

. /etc/os-release
if [ "${ID}" != "ubuntu" ]; then
    echo "This script requires Ubuntu (detected: ${ID})."
    exit 1
fi

REQUIRED_VERSION="24.04"
if printf '%s\n' "${REQUIRED_VERSION}" "${VERSION_ID}" | sort -V | head -1 | grep -qv "${REQUIRED_VERSION}"; then
    echo "Ubuntu ${REQUIRED_VERSION} or later required (detected: ${VERSION_ID})."
    exit 1
fi

ARGO_VERSION="${ARGO_VERSION:-v3.6.4}"
RUNNER_USER="${RUNNER_USER:-$(logname 2>/dev/null || echo "${SUDO_USER:-runner}")}"

echo "=== kcli repository ==="
curl -1sLf https://dl.cloudsmith.io/public/karmab/kcli/cfg/setup/bash.deb.sh | bash

echo "=== APT packages ==="
apt-get update
apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    podman \
    crun \
    python3 \
    python3-pip \
    python3-venv \
    python3-kcli \
    ansible-core \
    genisoimage \
    util-linux \
    coreutils \
    curl \
    git \
    jq

echo "=== Add ${RUNNER_USER} to libvirt and kvm groups ==="
usermod -aG libvirt "${RUNNER_USER}"
usermod -aG kvm "${RUNNER_USER}"
echo "NOTE: group changes require re-login or 'newgrp libvirt' to take effect."

echo "=== Enable lingering for ${RUNNER_USER} (rootless podman in systemd services) ==="
loginctl enable-linger "${RUNNER_USER}"

echo "=== Enable and start libvirtd ==="
systemctl enable --now libvirtd

echo "=== Ensure default storage pool exists ==="
if ! virsh pool-info default &>/dev/null; then
    virsh pool-define-as default dir --target /var/lib/libvirt/images
    virsh pool-build default
    virsh pool-start default
    virsh pool-autostart default
    echo "Created and started default storage pool"
else
    virsh pool-start default 2>/dev/null || true
    virsh pool-autostart default 2>/dev/null || true
    echo "Default storage pool already exists"
fi
setfacl -m u:"${RUNNER_USER}":rwx /var/lib/libvirt/images

echo "=== kubectl ==="
if ! command -v kubectl &>/dev/null; then
    KUBECTL_VERSION=$(curl -Ls https://dl.k8s.io/release/stable.txt)
    curl -Lo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    install /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
    echo "Installed kubectl ${KUBECTL_VERSION}"
else
    echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

echo "=== Helm 4 ==="
if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
else
    echo "helm already installed: $(helm version --short)"
fi

echo "=== Argo CLI ${ARGO_VERSION} ==="
if ! command -v argo &>/dev/null; then
    curl -sLo /tmp/argo "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/argo-linux-amd64.gz"
    # The release asset is gzipped despite the URL; handle both cases
    if file /tmp/argo | grep -q gzip; then
        mv /tmp/argo /tmp/argo.gz
        gunzip /tmp/argo.gz
    fi
    install /tmp/argo /usr/local/bin/argo
    rm -f /tmp/argo
    echo "Installed argo ${ARGO_VERSION}"
else
    echo "argo already installed: $(argo version --short 2>/dev/null || argo version)"
fi

echo "=== Persistent results directory ==="
mkdir -p /var/lib/kata-e2e/results
chown "${RUNNER_USER}" /var/lib/kata-e2e/results

echo "=== /dev/kvm check ==="
if [ -e /dev/kvm ]; then
    echo "/dev/kvm exists (OK)"
else
    echo "WARNING: /dev/kvm not found. KVM acceleration will not work."
fi

echo "=== Pre-pull container registry image ==="
su - "${RUNNER_USER}" -c "podman pull docker.io/library/registry:2" || true

echo "=== Download kcli base image ==="
su - "${RUNNER_USER}" -c "kcli download image ubuntu2404" || true

cat <<'EOF'

====================================================================
  Setup complete.
====================================================================

  The only remaining manual step:

  1. GitHub Actions self-hosted runner
     See https://github.com/organizations/<ORG>/settings/actions/runners
     Download, configure, and install as a systemd service.

  Verify installation:
    for cmd in kcli kubectl helm argo podman python3 ansible-playbook; do
      printf "%-20s %s\n" "$cmd" "$(command -v $cmd && echo OK || echo MISSING)"
    done

====================================================================
EOF
