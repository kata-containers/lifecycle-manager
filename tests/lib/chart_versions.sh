# Copyright (c) 2026 The Kata Containers Authors
# SPDX-License-Identifier: Apache-2.0
#
# Released kata-deploy chart versions, read from the chart registry so nothing
# here has to be edited when kata-deploy makes a release. Sourced by the E2E
# runner (which upgrades between them) and by rbac_coverage.py (which checks
# what they ask for), so both look at the same list.

CHART_REGISTRY_REPO="${CHART_REGISTRY_REPO:-ghcr.io/kata-containers/kata-deploy-charts/kata-deploy}"

# Released versions, oldest first. Pre-release tags (0.0.0-dev, the occasional
# -testing) are left out: they are not points to upgrade between.
list_released_chart_versions() {
    local repo="${CHART_REGISTRY_REPO#*/}" token

    token=$(curl -fsSL --max-time 30 \
        "https://ghcr.io/token?scope=repository:${repo}:pull&service=ghcr.io" \
        | jq -r '.token // empty') || return 1
    [ -n "${token}" ] || return 1

    curl -fsSL --max-time 30 -H "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${repo}/tags/list" \
        | jq -r '.tags[]?' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V
}
