#!/usr/bin/env bash
# Copyright (c) 2026 The Kata Containers Authors
# SPDX-License-Identifier: Apache-2.0
#
# E2E test runner for kata-lifecycle-manager.
# Runs each test case as a separate ansible-playbook invocation,
# collects results, and generates JUnit XML + summary reports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg"

# -- Defaults --
RUNTIME=""
TC_FILTER="all"
SKIP_CLUSTER_CREATE=false
SKIP_CLUSTER_DELETE=false
FROM_VERSION=""
TO_VERSION=""
TO_IMAGE=""
DEPLOYMENT_MODE=""
BATCH_SIZE=""
KATA_DEPLOY_CHART=""
RESULTS_DIR="${SCRIPT_DIR}/results"
ROTATE_LOGS_ONLY=false
SETUP_ONLY=false
SKIP_SETUP=false
REPORTS_ONLY=false

# -- Log rotation defaults (overridable via environment variables) --
RESULTS_BASE_DIR="${RESULTS_BASE_DIR:-/var/lib/kata-e2e/results}"
RESULTS_MAX_RUNS="${RESULTS_MAX_RUNS:-10}"
RESULTS_MAX_AGE_DAYS="${RESULTS_MAX_AGE_DAYS:-30}"
RESULTS_MAX_TOTAL_MB="${RESULTS_MAX_TOTAL_MB:-2048}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --runtime <kata-qemu|kata-qemu-coco-dev>  Runtime class to test (required)
  --tc <N|N,M,...|all>                      Test cases to run (default: all)
  --skip-cluster-create                     Reuse existing cluster
  --skip-cluster-delete                     Keep cluster after tests
  --from-version <version>                  Override kata_from_version
  --to-version <version>                    Override kata_to_version (0.0.0-dev = chart
                                            built from kata main)
  --to-image <image>                        Override kata_to_image (empty = the image the
                                            chart of that version defaults to; must stay
                                            on the same side of released vs. main)
  --deployment-mode <daemonset|job>         Override deployment_mode (default: daemonset)
  --batch-size <N>                          Override batch_size (default: 1 = node-by-node)
  --kata-deploy-chart <ref|path>            Override kata_deploy_chart (OCI ref or local
                                            kata-containers checkout; needed to test job
                                            mode before it ships in a released chart)
  --results-dir <path>                      Output directory (default: ./results)
  --rotate-logs-only                        Only perform log rotation, then exit
  --setup-only                              Run setup, write env.sh, then exit
  --skip-setup                              Skip setup (expects env.sh to exist)
  --reports-only                            Generate reports from results.json
  -h, --help                                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime)           RUNTIME="$2"; shift 2 ;;
        --tc)                TC_FILTER="$2"; shift 2 ;;
        --skip-cluster-create) SKIP_CLUSTER_CREATE=true; shift ;;
        --skip-cluster-delete) SKIP_CLUSTER_DELETE=true; shift ;;
        --from-version)      FROM_VERSION="$2"; shift 2 ;;
        --to-version)        TO_VERSION="$2"; shift 2 ;;
        --to-image)          TO_IMAGE="$2"; shift 2 ;;
        --deployment-mode)   DEPLOYMENT_MODE="$2"; shift 2 ;;
        --batch-size)        BATCH_SIZE="$2"; shift 2 ;;
        --kata-deploy-chart) KATA_DEPLOY_CHART="$2"; shift 2 ;;
        --results-dir)       RESULTS_DIR="$2"; shift 2 ;;
        --rotate-logs-only)  ROTATE_LOGS_ONLY=true; shift ;;
        --setup-only)        SETUP_ONLY=true; shift ;;
        --skip-setup)        SKIP_SETUP=true; shift ;;
        --reports-only)      REPORTS_ONLY=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# A kata-deploy image only fits the chart it shipped with: it expects the mounts
# and security context that chart renders, and running it under another
# version's chart crash-loops the pod, which shows up as an upgrade that never
# finishes. kata-containers-latest is built from main, so 0.0.0-dev (the chart
# published from main) is the only chart it goes with.
check_chart_image_pair() {
    local what="$1" version="$2" image="$3"
    local dev_chart="0.0.0-dev" dev_tag="kata-containers-latest"

    [ -n "${image}" ] || return 0
    # An unset version leaves the harness on its default, which is a release.
    if [ "${image##*:}" = "${dev_tag}" ] && [ "${version:-release default}" != "${dev_chart}" ]; then
        echo "ERROR: ${what} pairs the ${dev_tag} image with chart ${version:-release default}."
        echo "       That image is built from kata main, so it needs the chart"
        echo "       built from main: pass ${dev_chart} as the version, or point"
        echo "       at the image released with that chart."
        exit 1
    fi
    if [ "${version}" = "${dev_chart}" ] && [ "${image##*:}" != "${dev_tag}" ]; then
        echo "ERROR: ${what} pairs chart ${dev_chart} with image ${image}."
        echo "       The chart built from main needs an image built from main;"
        echo "       leave the image empty to take the one the chart defaults to."
        exit 1
    fi
}

check_chart_image_pair "--to-version/--to-image" "${TO_VERSION}" "${TO_IMAGE}"

# =========================================================================
# Log Rotation
# =========================================================================
rotate_logs() {
    mkdir -p "${RESULTS_BASE_DIR}"

    flock --timeout 30 "${RESULTS_BASE_DIR}/.rotation.lock" bash -c '
        RESULTS_BASE_DIR="'"${RESULTS_BASE_DIR}"'"
        RESULTS_MAX_AGE_DAYS="'"${RESULTS_MAX_AGE_DAYS}"'"
        RESULTS_MAX_RUNS="'"${RESULTS_MAX_RUNS}"'"
        RESULTS_MAX_TOTAL_MB="'"${RESULTS_MAX_TOTAL_MB}"'"

        # 1. Age-based: delete run directories older than N days
        find "$RESULTS_BASE_DIR" -maxdepth 1 -mindepth 1 -type d \
            -mtime +"${RESULTS_MAX_AGE_DAYS}" -exec rm -rf {} + 2>/dev/null || true

        # 2. Count-based: keep only the most recent N directories
        ls -1dt "$RESULTS_BASE_DIR"/*/ 2>/dev/null \
            | tail -n +"$((RESULTS_MAX_RUNS + 1))" \
            | xargs -r rm -rf 2>/dev/null || true

        # 3. Size-based: delete oldest until under limit
        while [ "$(du -sm "$RESULTS_BASE_DIR" 2>/dev/null | cut -f1)" -gt "${RESULTS_MAX_TOTAL_MB}" ] 2>/dev/null; do
            OLDEST=$(ls -1dt "$RESULTS_BASE_DIR"/*/ 2>/dev/null | tail -1)
            [ -z "$OLDEST" ] && break
            rm -rf "$OLDEST"
        done
    '
    echo "[INFO] Log rotation complete"
}

if [ "${ROTATE_LOGS_ONLY}" = true ]; then
    rotate_logs
    exit 0
fi

# =========================================================================
# Report generation (function used by normal flow and --reports-only)
# =========================================================================
generate_reports() {
    local results_dir="$1"
    local runtime="$2"

    local total failed passed total_time
    read -r total failed passed total_time <<< "$(python3 -c "
import json
with open('${results_dir}/results.json') as f:
    data = json.load(f)
total = len(data)
failed = sum(1 for r in data if r['status'] == 'FAILED')
passed = total - failed
total_time = sum(r['duration'] for r in data)
print(total, failed, passed, total_time)
" 2>/dev/null || echo "0 0 0 0")"

    python3 - "${results_dir}/results.json" "${results_dir}/junit.xml" "${runtime}" <<'PYEOF'
import json, sys, html

results_file, output_file, runtime = sys.argv[1], sys.argv[2], sys.argv[3]

with open(results_file) as f:
    results = json.load(f)

total = len(results)
failures = sum(1 for r in results if r["status"] == "FAILED")
total_time = sum(r["duration"] for r in results)

lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    f'<testsuites>',
    f'  <testsuite name="kata-lifecycle-manager-e2e ({runtime})" tests="{total}" failures="{failures}" time="{total_time}">',
]

for r in results:
    tc_name = f'{r["number"]}: {r["name"]}'
    if r["status"] == "PASSED":
        lines.append(f'    <testcase name="{html.escape(tc_name)}" classname="{runtime}" time="{r["duration"]}" />')
    else:
        error_msg = html.escape(r.get("error", "See log for details"))
        lines.append(f'    <testcase name="{html.escape(tc_name)}" classname="{runtime}" time="{r["duration"]}">')
        lines.append(f'      <failure message="{error_msg}">{error_msg}</failure>')
        lines.append(f'    </testcase>')

lines.append('  </testsuite>')
lines.append('</testsuites>')

with open(output_file, 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF

    {
    echo ""
    echo "=================================================================="
    echo "  KATA LIFECYCLE MANAGER E2E RESULTS -- ${runtime}"
    echo "=================================================================="

    python3 -c "
import json
with open('${results_dir}/results.json') as f:
    for r in json.load(f):
        m, s = divmod(r['duration'], 60)
        print(f'  {r[\"number\"]}  {r[\"name\"]:<45} {r[\"status\"]:<8} {m}m{s:02d}s')
"

    echo "------------------------------------------------------------------"
    local suite_min=$((total_time / 60))
    local suite_sec=$((total_time % 60))
    echo "  Total: ${total} | Passed: ${passed} | Failed: ${failed} | Duration: ${suite_min}m${suite_sec}s"
    echo "=================================================================="
    } >&2

    cat > "${results_dir}/summary.md" <<MDEOF
| Test Case | Name | Status | Duration |
|-----------|------|--------|----------|
MDEOF

    python3 -c "
import json
with open('${results_dir}/results.json') as f:
    for r in json.load(f):
        m, s = divmod(r['duration'], 60)
        print(f'| {r[\"number\"]} | {r[\"name\"]} | {r[\"status\"]} | {m}m{s:02d}s |')
" >> "${results_dir}/summary.md"

    echo "" >> "${results_dir}/summary.md"
    echo "**Total: ${total} | Passed: ${passed} | Failed: ${failed} | Duration: ${suite_min}m${suite_sec}s**" >> "${results_dir}/summary.md"

    if [ -d "${RESULTS_BASE_DIR}" ]; then
        local timestamp
        timestamp=$(date +%Y-%m-%d_%H%M%S)
        cp -r "${results_dir}" "${RESULTS_BASE_DIR}/${timestamp}-${runtime}" 2>/dev/null || true
    fi

    echo "${failed}"
}

# =========================================================================
# Reports-only mode
# =========================================================================
if [ "${REPORTS_ONLY}" = true ]; then
    if [ -z "${RUNTIME}" ]; then
        echo "[ERROR] --runtime is required for --reports-only"
        exit 1
    fi
    if [ ! -f "${RESULTS_DIR}/results.json" ]; then
        echo "[ERROR] ${RESULTS_DIR}/results.json not found"
        exit 1
    fi
    REPORT_FAILED=$(generate_reports "${RESULTS_DIR}" "${RUNTIME}")
    if [ "${REPORT_FAILED}" -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

# =========================================================================
# Validation
# =========================================================================
if [ -z "${RUNTIME}" ]; then
    echo "[ERROR] --runtime is required"
    usage
    exit 1
fi

# =========================================================================
# Test case discovery
# =========================================================================
declare -A TC_NAMES
TC_NAMES=(
    [01]="Basic Upgrade"
    [02]="Auto-Rollback Verification Failure"
    [03]="Manual Rollback"
    [04]="Taint and Combined Selection"
    [05]="Upgrade with Drain"
    [06]="Custom Image Upgrade"
    [07]="Verification Pod Override"
    [08]="No Matching Nodes"
    [09]="Timeout Auto-Rollback"
    [10]="Same Version Re-upgrade"
    [11]="No Workload Disruption"
    [12]="DaemonSet Target Node Only"
    [13]="Node-by-Node Sequential"
    [14]="Partial Failure Stops"
    [15]="Drain Multi-Node"
    [16]="Wave-Based Batch Upgrade"
    [17]="Reject Deployment-Mode Switch"
    [18]="Auto-Detect Deployment Mode"
    [19]="Wave Partial Failure Rollback"
    [20]="Release Values Preserved"
)

declare -A TC_FILES
for num in "${!TC_NAMES[@]}"; do
    pattern="${SCRIPT_DIR}/playbooks/tc${num}_*.yaml"
    # shellcheck disable=SC2086
    file=$(ls ${pattern} 2>/dev/null | head -1)
    if [ -n "${file}" ]; then
        TC_FILES[${num}]="${file}"
    fi
done

# Test cases to skip due to known upstream issues.
SKIP_TCS=()

# Filter test cases
if [ "${TC_FILTER}" = "all" ]; then
    SELECTED_TCS=($(echo "${!TC_NAMES[@]}" | tr ' ' '\n' | sort))
else
    IFS=',' read -ra SELECTED_TCS <<< "${TC_FILTER}"
    # Zero-pad single digits
    for i in "${!SELECTED_TCS[@]}"; do
        SELECTED_TCS[$i]=$(printf "%02d" "${SELECTED_TCS[$i]}")
    done
fi

# Remove skipped test cases
for skip in "${SKIP_TCS[@]}"; do
    skip_padded=$(printf "%02d" "$skip")
    FILTERED=()
    for tc in "${SELECTED_TCS[@]}"; do
        if [ "$tc" != "$skip_padded" ]; then
            FILTERED+=("$tc")
        else
            echo "[SKIP] TC-${skip_padded}: ${TC_NAMES[$skip_padded]:-unknown} (known issue)"
        fi
    done
    SELECTED_TCS=("${FILTERED[@]}")
done

# =========================================================================
# Setup
# =========================================================================
mkdir -p "${RESULTS_DIR}/logs"

if [ "${SKIP_SETUP}" != true ]; then
    echo "=================================================================="
    echo "  KATA LIFECYCLE MANAGER E2E TESTS"
    echo "=================================================================="
    echo "  Runtime:      ${RUNTIME}"
    echo "  Test cases:   ${SELECTED_TCS[*]}"
    echo "  Results dir:  ${RESULTS_DIR}"
    echo "=================================================================="
    echo ""

    rotate_logs
fi
if [ ! -f "${RESULTS_DIR}/results.json" ]; then
    echo "[]" > "${RESULTS_DIR}/results.json"
fi

# Build extra-vars for ansible-playbook
build_extra_vars() {
    EXTRA_VARS="kata_runtime_class=${RUNTIME}"
    EXTRA_VARS="${EXTRA_VARS} skip_cluster_create=${SKIP_CLUSTER_CREATE}"
    EXTRA_VARS="${EXTRA_VARS} skip_cluster_delete=${SKIP_CLUSTER_DELETE}"
    if [ -n "${FROM_VERSION}" ]; then
        EXTRA_VARS="${EXTRA_VARS} kata_from_version=${FROM_VERSION}"
    fi
    if [ -n "${TO_VERSION}" ]; then
        EXTRA_VARS="${EXTRA_VARS} kata_to_version=${TO_VERSION}"
    fi
    if [ -n "${TO_IMAGE}" ]; then
        EXTRA_VARS="${EXTRA_VARS} kata_to_image=${TO_IMAGE}"
    fi
    if [ -n "${DEPLOYMENT_MODE}" ]; then
        EXTRA_VARS="${EXTRA_VARS} deployment_mode=${DEPLOYMENT_MODE}"
    fi
    if [ -n "${BATCH_SIZE}" ]; then
        EXTRA_VARS="${EXTRA_VARS} batch_size=${BATCH_SIZE}"
    fi
    if [ -n "${KATA_DEPLOY_CHART}" ]; then
        EXTRA_VARS="${EXTRA_VARS} kata_deploy_chart=${KATA_DEPLOY_CHART}"
    fi

    CLUSTER_NAME="kata-e2e-${RUNTIME}"
    EXTRA_VARS="${EXTRA_VARS} cluster_name=${CLUSTER_NAME}"
    export KUBECONFIG="${HOME}/.kcli/clusters/${CLUSTER_NAME}/auth/kubeconfig"
}

build_extra_vars

if [ "${SKIP_SETUP}" = true ]; then
    # Load previously saved environment from setup-only run
    if [ -f "${RESULTS_DIR}/env.sh" ]; then
        # shellcheck disable=SC1091
        source "${RESULTS_DIR}/env.sh"
    else
        echo "[WARN] --skip-setup specified but ${RESULTS_DIR}/env.sh not found"
        echo "[INFO] Attempting to discover nodes from live cluster..."
        WORKER_NODE_A=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
        WORKER_NODE_B=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[1].metadata.name}')
        CONTROL_PLANE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
    fi
    EXTRA_VARS="${EXTRA_VARS} worker_node_a=${WORKER_NODE_A}"
    EXTRA_VARS="${EXTRA_VARS} worker_node_b=${WORKER_NODE_B}"
    EXTRA_VARS="${EXTRA_VARS} control_plane_node=${CONTROL_PLANE}"
else
    echo "::group::Setup (registry, cluster, argo, kata-deploy, lifecycle-manager)"
    echo "[INFO] Running setup playbook..."
    if ansible-playbook \
        -e "${EXTRA_VARS}" \
        "${SCRIPT_DIR}/playbooks/setup.yaml" \
        2>&1 | tee "${RESULTS_DIR}/logs/setup.log"; then
        echo "[INFO] Setup completed successfully"
    else
        echo "::endgroup::"
        echo "[FAIL] Setup failed. See ${RESULTS_DIR}/logs/setup.log"
        exit 1
    fi

    WORKER_NODE_A=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
    WORKER_NODE_B=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[1].metadata.name}')
    CONTROL_PLANE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')

    echo "[INFO] Nodes: control_plane=${CONTROL_PLANE} worker_a=${WORKER_NODE_A} worker_b=${WORKER_NODE_B}"

    EXTRA_VARS="${EXTRA_VARS} worker_node_a=${WORKER_NODE_A}"
    EXTRA_VARS="${EXTRA_VARS} worker_node_b=${WORKER_NODE_B}"
    EXTRA_VARS="${EXTRA_VARS} control_plane_node=${CONTROL_PLANE}"

    # Write env.sh so subsequent --skip-setup invocations can reuse it
    cat > "${RESULTS_DIR}/env.sh" <<ENVEOF
export KUBECONFIG="${KUBECONFIG}"
export WORKER_NODE_A="${WORKER_NODE_A}"
export WORKER_NODE_B="${WORKER_NODE_B}"
export CONTROL_PLANE="${CONTROL_PLANE}"
ENVEOF

    echo "::endgroup::"

    if [ "${SETUP_ONLY}" = true ]; then
        echo "[INFO] Setup-only mode: exiting after setup"
        exit 0
    fi
fi

# =========================================================================
# Run test cases
# =========================================================================
TOTAL=0
PASSED=0
FAILED=0
SUITE_START=$(date +%s)

for tc_num in "${SELECTED_TCS[@]}"; do
    tc_name="${TC_NAMES[${tc_num}]:-Unknown}"
    tc_file="${TC_FILES[${tc_num}]:-}"
    tc_log="${RESULTS_DIR}/logs/tc${tc_num}.log"

    if [ -z "${tc_file}" ]; then
        echo "[SKIP] TC-${tc_num}: ${tc_name} (playbook not found)"
        continue
    fi

    TOTAL=$((TOTAL + 1))
    echo ""
    echo "::group::TC-${tc_num}: ${tc_name}"
    echo "[RUN]  TC-${tc_num}: ${tc_name}"

    TC_START=$(date +%s)

    if ansible-playbook \
        -e "${EXTRA_VARS}" \
        "${tc_file}" \
        2>&1 | tee "${tc_log}"; then
        TC_STATUS="PASSED"
        PASSED=$((PASSED + 1))
        TC_ERROR=""
    else
        TC_STATUS="FAILED"
        FAILED=$((FAILED + 1))
        TC_ERROR=$(tail -20 "${tc_log}" | grep -i "fail\|error\|assert" | head -3 | tr '\n' ' ' || echo "See log for details")
    fi

    TC_END=$(date +%s)
    TC_DURATION=$((TC_END - TC_START))

    echo "::endgroup::"
    echo "[${TC_STATUS}] TC-${tc_num}: ${tc_name} (${TC_DURATION}s)"

    # Append to results JSON
    TC_NUM="${tc_num}" TC_NAME="${tc_name}" TC_STATUS_VAL="${TC_STATUS}" \
    TC_DUR="${TC_DURATION}" TC_ERR="${TC_ERROR}" \
    python3 -c "
import json, os
with open('${RESULTS_DIR}/results.json') as f:
    data = json.load(f)
data.append({
    'number': 'TC-' + os.environ['TC_NUM'],
    'name': os.environ['TC_NAME'],
    'status': os.environ['TC_STATUS_VAL'],
    'duration': int(os.environ['TC_DUR']),
    'error': os.environ.get('TC_ERR', ''),
})
with open('${RESULTS_DIR}/results.json', 'w') as f:
    json.dump(data, f, indent=2)
"
done

SUITE_END=$(date +%s)
SUITE_DURATION=$((SUITE_END - SUITE_START))

# =========================================================================
# Generate reports (skip when running individual TCs via --skip-setup;
# the --reports-only step handles aggregated reporting)
# =========================================================================
if [ "${SKIP_SETUP}" != true ]; then
    REPORT_FAILED=$(generate_reports "${RESULTS_DIR}" "${RUNTIME}")
fi

# =========================================================================
# Teardown
# =========================================================================
if [ "${SKIP_CLUSTER_DELETE}" != true ]; then
    echo ""
    echo "::group::Teardown"
    echo "[INFO] Running teardown playbook..."
    ansible-playbook \
        -e "${EXTRA_VARS}" \
        "${SCRIPT_DIR}/playbooks/teardown.yaml" \
        2>&1 | tee "${RESULTS_DIR}/logs/teardown.log" || true
    echo "::endgroup::"
fi

# =========================================================================
# Exit
# =========================================================================
if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
