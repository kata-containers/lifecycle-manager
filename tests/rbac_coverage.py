#!/usr/bin/env python3
# Copyright (c) 2026 The Kata Containers Authors
# SPDX-License-Identifier: Apache-2.0

"""Check that this chart's ClusterRole covers what the kata-deploy chart grants.

Upgrading kata-deploy means applying its chart, and that chart carries
kata-deploy's own ClusterRole. Kubernetes refuses to let an account create or
update a role granting rights it does not hold, so this chart's ClusterRole has
to be a superset of kata-deploy's -- including permissions the workflow never
uses itself. A kata-deploy release that widens its role therefore breaks every
upgrade until this chart mirrors the new rule, and the E2E suite only finds out
by spending a cluster and an hour to fail with an opaque "attempting to grant
RBAC permissions not currently held".

This renders both charts instead and names the missing rules in seconds.

Only default values are rendered, which is what the suite installs. Enabling
node-feature-discovery pulls NFD's own roles into the release and needs its own
set of permissions; that is a separate gap, not covered here yet.

Usage:
  tests/rbac_coverage.py                    # newest released chart + 0.0.0-dev
  tests/rbac_coverage.py 4.0.0 0.0.0-dev    # explicit versions
"""

import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSIONS_LIB = REPO_ROOT / "tests" / "lib" / "chart_versions.sh"
KATA_DEPLOY_CHART = "oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy"
# The dispatcher in job mode comes with roles of its own, so both models are
# rendered: an upgrade has to be able to install whichever one the release uses.
DEPLOYMENT_MODES = ("daemonset", "job")


def run(*argv):
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"ERROR: {' '.join(argv)} failed:\n{result.stderr.strip()}")
    return result.stdout


def latest_released_version():
    versions = run(
        "bash", "-c", f'source "{VERSIONS_LIB}"; list_released_chart_versions'
    ).split()
    if not versions:
        sys.exit(
            "ERROR: could not list released kata-deploy chart versions.\n"
            "       Pass the versions to check as arguments to run offline."
        )
    return versions[-1]


def rules_in(manifests):
    """Every rule the rendered manifests hand out, as (group, resource, verb)."""
    granted = set()
    for doc in yaml.safe_load_all(manifests):
        if not doc or doc.get("kind") not in ("ClusterRole", "Role"):
            continue
        for rule in doc.get("rules") or []:
            if rule.get("nonResourceURLs"):
                print(
                    f"NOTE: {doc['metadata']['name']} has a nonResourceURLs rule, "
                    "which this check does not compare"
                )
            for group in rule.get("apiGroups") or []:
                for resource in rule.get("resources") or []:
                    for verb in rule.get("verbs") or []:
                        granted.add((group, resource, verb))
    return granted


def render_lifecycle_manager():
    # The chart refuses to render without a verification pod; its content is
    # irrelevant to RBAC.
    return rules_in(
        run(
            "helm", "template", "rbac-coverage", str(REPO_ROOT),
            "--set", "defaults.verificationPod=rbac-coverage",
        )
    )


def render_kata_deploy(version, mode):
    return rules_in(
        run(
            "helm", "template", "rbac-coverage", KATA_DEPLOY_CHART,
            "--version", version,
            "--set", f"deploymentMode={mode}",
        )
    )


def uncovered(granted, held):
    """The rules in `granted` that `held` does not cover.

    Wildcards are honoured on the holding side only: a chart that grants "*"
    would be reported verbatim, which is the right thing to look at anyway.
    """
    missing = set()
    for group, resource, verb in granted:
        if any(
            (group in (held_group, "*"))
            and (resource in (held_resource, "*"))
            and (verb in (held_verb, "*"))
            for held_group, held_resource, held_verb in held
        ):
            continue
        missing.add((group, resource, verb))
    return missing


def as_rules(triples):
    """Group triples back into ClusterRole rules, one per (group, resource)."""
    verbs_by_target = {}
    for group, resource, verb in triples:
        verbs_by_target.setdefault((group, resource), set()).add(verb)
    return [
        {
            "apiGroups": [group],
            "resources": [resource],
            "verbs": sorted(verbs),
        }
        for (group, resource), verbs in sorted(verbs_by_target.items())
    ]


def main():
    versions = sys.argv[1:] or [latest_released_version(), "0.0.0-dev"]
    held = render_lifecycle_manager()

    missing = set()
    for version in versions:
        for mode in DEPLOYMENT_MODES:
            granted = render_kata_deploy(version, mode)
            gap = uncovered(granted, held)
            print(
                f"kata-deploy {version} ({mode} mode): {len(granted)} permissions, "
                f"{len(gap)} not held"
            )
            missing |= gap

    if not missing:
        print("\nThe kata-lifecycle-manager ClusterRole covers all of them.")
        return 0

    rules = as_rules(missing)
    print(
        "\nThese are granted by the kata-deploy chart and not held by the "
        "kata-lifecycle-manager ClusterRole, so upgrading to it fails with\n"
        '"attempting to grant RBAC permissions not currently held".\n'
        "\nAdd to templates/rbac.yaml:\n"
    )
    print(yaml.safe_dump(rules, default_flow_style=None).rstrip())
    print(
        "\nUntil a release carries them, cluster admins can grant the same rules "
        "with rbac.extraRules."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
