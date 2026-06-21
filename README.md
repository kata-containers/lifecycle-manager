# Kata Lifecycle Manager Helm Chart

[![E2E Tests](https://github.com/kata-containers/lifecycle-manager/actions/workflows/e2e-tests.yaml/badge.svg?branch=main)](https://github.com/kata-containers/lifecycle-manager/actions/workflows/e2e-tests.yaml)

Argo Workflows-based lifecycle management for Kata Containers.

This chart installs a namespace-scoped `WorkflowTemplate` that performs controlled
upgrades of kata-deploy with verification and automatic rollback on failure. **You choose
the rollout granularity**: strict **node-by-node** (the default) or, by raising `batch-size`,
larger **waves** of nodes at a time (important for large fleets where one-at-a-time does not
scale). It supports both kata-deploy deployment models (DaemonSet and the newer Job mode).
See [Deployment Modes](#deployment-modes-daemonset-vs-job) and
[Node-by-Node vs Waves](#node-by-node-vs-waves-batch-size).

## Prerequisites

- Kubernetes cluster with **kata-deploy installed via Helm**. Minimum chart version depends on the [deployment mode](#deployment-modes-daemonset-vs-job):
  - **daemonset** mode: **3.27.0 or higher** (the workflow relies on the chart setting DaemonSet `updateStrategy.type=OnDelete`)
  - **job** mode: **3.32.0 or higher** (first release shipping Job mode, kata-containers PR #13155)
- **Argo Workflows** v3.4+ installed **before** installing kata-lifecycle-manager (this chart only installs the `WorkflowTemplate`; it does not install Argo). Installation guide: [Argo Workflows releases](https://github.com/argoproj/argo-workflows/releases/) (not Argo CD)
- `helm` CLI and `argo` CLI (Argo Workflows CLI, not `argocd`)
- **Verification pod spec** (see [Verification Pod](#verification-pod-required))

## Installation

**1. Install Argo Workflows first** (if not already installed). See the [Argo Workflows installation guide](https://github.com/argoproj/argo-workflows/releases/).

**2. Install the chart** from the OCI registry (published on [GitHub Releases](https://github.com/kata-containers/lifecycle-manager/releases)):

```bash
# Install latest (or pin a version with --version $version)
helm install kata-lifecycle-manager oci://ghcr.io/kata-containers/kata-lifecycle-manager-charts/kata-lifecycle-manager \
  --namespace argo
```

For development from a local clone: `helm install kata-lifecycle-manager . --namespace argo`

## Verification Pod (Required)

A verification pod is **required** to validate each node after upgrade. The chart
will fail to install without one.

### Option A: Bake into kata-lifecycle-manager (recommended)

Provide the verification pod when installing the chart:

```bash
helm install kata-lifecycle-manager oci://ghcr.io/kata-containers/kata-lifecycle-manager-charts/kata-lifecycle-manager \
  --namespace argo \
  --set-file defaults.verificationPod=./my-verification-pod.yaml
```

This verification pod is baked into the `WorkflowTemplate` and used for all upgrades.

### Option B: Override at workflow submission

One-off override for a specific upgrade run. The pod spec must be base64-encoded
because Argo workflow parameters don't handle multi-line YAML reliably:

```bash
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0 \
  -p verification-pod="$(base64 -w0 < ./my-verification-pod.yaml)"
```

**Note:** During helm upgrade, `kata-deploy`'s own verification is disabled
(`--set verification.pod=""`). This is because `kata-deploy`'s verification is
cluster-wide (designed for initial install), while kata-lifecycle-manager performs
per-node verification with proper placeholder substitution.

### Verification Pod Spec

Create a pod spec that validates your Kata deployment. The pod should exit 0 on success,
non-zero on failure.

**Example (`my-verification-pod.yaml`):**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
spec:
  runtimeClassName: kata-qemu
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  tolerations:
    - operator: Exists
  containers:
    - name: verify
      image: quay.io/kata-containers/alpine-bash-curl:latest
      command:
        - sh
        - -c
        - |
          echo "=== Kata Verification ==="
          echo "Node: ${NODE}"
          echo "Kernel: $(uname -r)"
          echo "SUCCESS: Pod running with Kata runtime"
```

### Placeholders

| Placeholder | Description |
|-------------|-------------|
| `${NODE}` | Node hostname being upgraded/verified |
| `${TEST_POD}` | Generated unique pod name |

**You are responsible for:**
- Setting the `runtimeClassName` in your pod spec
- Defining the verification logic in your container
- Using the exit code to indicate success (0) or failure (non-zero)

**Failure modes detected:**
- Pod stuck in Pending/`ContainerCreating` (runtime can't start VM)
- Pod crashes immediately (containerd/CRI-O configuration issues)
- Pod times out (resource issues, image pull failures)
- Pod exits with non-zero code (verification logic failed)

All of these trigger automatic rollback.

## Usage

### 1. Select Nodes for Upgrade

Nodes can be selected using **labels**, **taints**, or **both**.

**Option A: Label-based selection (default)**

```bash
# Label nodes for upgrade
kubectl label node worker-1 katacontainers.io/kata-lifecycle-manager-window=true

# Trigger upgrade
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0 \
  -p node-selector="katacontainers.io/kata-lifecycle-manager-window=true"
```

**Option B: Taint-based selection**

```bash
# Taint nodes for upgrade
kubectl taint nodes worker-1 kata-lifecycle-manager=pending:NoSchedule

# Trigger upgrade using taint selector
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0 \
  -p node-taint-key=kata-lifecycle-manager \
  -p node-taint-value=pending
```

**Option C: Combined selection**

```bash
# Use both labels and taints for precise targeting
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0 \
  -p node-selector="node-pool=kata-pool" \
  -p node-taint-key=kata-lifecycle-manager
```

### 2. Trigger Upgrade

```bash
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0

# Watch progress
argo watch @latest
```

### 3. Node-by-Node (default) or Waves

By default (`batch-size=1`) nodes are upgraded **strictly one at a time**: each node is
verified before the next is touched. If you prefer, raise `batch-size` to upgrade in
**waves** of N nodes at a time. Either way, after each node/wave the affected node(s) are
verified; if any fails verification it is rolled back and the workflow stops immediately,
so you never end up with a large mixed-version fleet. See
[Node-by-Node vs Waves](#node-by-node-vs-waves-batch-size).

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `argoNamespace` | Namespace for Argo resources | `argo` |
| `defaults.helmRelease` | kata-deploy Helm release name | `kata-deploy` |
| `defaults.helmNamespace` | kata-deploy namespace | `kube-system` |
| `defaults.deploymentMode` | kata-deploy model: `auto` \| `daemonset` \| `job` (`auto` detects from the release) | `auto` |
| `defaults.batchSize` | Nodes upgraded per wave (`1` = strict node-by-node) | `1` |
| `defaults.nodeSelector` | Node label selector (optional if using taints) | `""` |
| `defaults.nodeTaintKey` | Taint key for node selection | `""` |
| `defaults.nodeTaintValue` | Taint value filter (optional) | `""` |
| `defaults.verificationNamespace` | Namespace for verification pods | `default` |
| `defaults.verificationPod` | Pod YAML for verification **(required)** | `""` |
| `defaults.drainEnabled` | Enable node drain before upgrade | `false` |
| `defaults.drainTimeout` | Timeout for drain operation | `300s` |
| `defaults.helmSetValues` | Extra `--set` values for `helm upgrade` (see [Custom Image](#custom-image)) | `""` |
| `images.utils` | Image with Helm 4 and kubectl (multi-arch) | `ghcr.io/kata-containers/lifecycle-manager-utils:latest` |

## Workflow Parameters

When submitting a workflow, you can override:

| Parameter | Description |
|-----------|-------------|
| `target-version` | **Required** - Target Kata version |
| `helm-release` | Helm release name |
| `helm-namespace` | Namespace of kata-deploy |
| `deployment-mode` | `auto` \| `daemonset` \| `job` (`auto` detects from the release) |
| `batch-size` | Nodes upgraded per wave (`1` = strict node-by-node) |
| `node-selector` | Label selector for nodes |
| `node-taint-key` | Taint key for node selection |
| `node-taint-value` | Taint value filter |
| `verification-namespace` | Namespace for verification pods |
| `verification-pod` | Pod YAML with placeholders |
| `drain-enabled` | Whether to drain nodes before upgrade |
| `drain-timeout` | Timeout for drain operation |
| `helm-set-values` | Extra `--set` values for `helm upgrade` (see [Custom Image](#custom-image)) |

## Deployment Modes (DaemonSet vs Job)

kata-deploy can install Kata on nodes two ways, and kata-lifecycle-manager supports both.
`deployment-mode=auto` (the default) detects which the target release uses by reading
its Helm values (`deploymentMode`), so you normally do not need to set it.

| Mode | kata-deploy model | How a wave is applied | Min chart |
|------|-------------------|-----------------------|-----------|
| `daemonset` | Long-running privileged DaemonSet (chart default) | `helm upgrade` once with `updateStrategy.type=OnDelete`, then delete the kata-deploy pod on each node in the wave to roll it | `3.27.0` |
| `job` | No resident component; a dispatcher Job fans out short-lived per-node install Jobs | one `helm upgrade --set 'job.nodes={...wave...}'` per wave; the dispatcher installs the wave's nodes concurrently (`job.parallelism` = wave size) and Helm blocks until they finish | `3.32.0` |

In **job mode** there is no DaemonSet and no `updateStrategy`. The workflow scopes each
`helm upgrade` to just the wave's nodes via `job.nodes`, so kata-deploy's dispatcher only
installs those nodes — giving the same wave-by-wave control. Rollback in job mode cannot
use `helm rollback` (it would not re-run the dispatcher), so a failed node is reverted by a
scoped re-upgrade to the previous chart version.

> **Note:** kata-deploy keeps the DaemonSet as its default for now, but Job mode becomes the
> default in Kata 4.0 and the DaemonSet is slated for removal around 4.2. Job mode is the
> forward-looking path.

### Switching an existing release between modes

kata-lifecycle-manager upgrades nodes in scoped waves and assumes the release is **already**
in the requested mode. It will **not** flip `deploymentMode` on a live release, because that
adds/removes the kata-deploy DaemonSet cluster-wide in a single step that cannot be done
wave-by-wave. If the requested `deployment-mode` differs from the mode the release is
currently running, the workflow fails fast in `check-prerequisites` and prints the exact
migration command (it does not partially apply anything).

To migrate **daemonset → job**, do the one-time switch yourself, then resume controlled
upgrades:

```bash
# 1. One-time, cluster-wide switch to job mode (requires kata-deploy >= 3.32.0).
helm upgrade <release> \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --namespace <ns> --version 3.32.0 --reuse-values \
  --set deploymentMode=job --set verification.pod=

# 2. Confirm nodes are labeled, then run wave-by-wave upgrades as usual.
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.33.0 -p deployment-mode=job   # or deployment-mode=auto
```

Notes:
- Because job mode only exists from 3.32.0, the switch necessarily moves every targeted node
  to the chosen version at once; it cannot be staged. Subsequent upgrades are wave-by-wave again.
- Already-installed host artifacts are not removed, so running Kata workloads keep working
  across the switch.
- The reverse (**job → daemonset**) works the same way with
  `--set deploymentMode=daemonset --set updateStrategy.type=OnDelete`.

## Node-by-Node vs Waves (`batch-size`)

You decide the rollout granularity with `batch-size`:

- `batch-size=1` (**default**): strict **node-by-node** — verify each node before touching
  the next. Safest, slowest; ideal for canaries and small/critical fleets.
- `batch-size=N`: upgrade up to **N nodes per wave**, verify the whole wave, then continue;
  on any verification failure the failed node(s) are rolled back and the workflow stops.

Both behave identically with respect to verification and fail-fast — the only difference is
how many nodes are in flight at once. Node-by-node remains fully supported and is the
default; waves are an opt-in for when one-at-a-time does not scale (e.g. ~1000 nodes):

```bash
# Node-by-node (default): nothing extra to set
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.32.0

# Waves: opt in by raising batch-size
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.32.0 \
  -p batch-size=50
```

In **job mode** the whole wave installs concurrently — `batch-size` is passed to the
kata-deploy dispatcher as `job.parallelism`. To pace how many CRI runtimes restart at once,
lower `batch-size` (the wave is cordoned and verified as a unit, so a smaller wave is the
right way to throttle).

## Deploy Flow

For each wave of up to `batch-size` selected nodes:

1. **Prepare**: Annotate each node with deploy status
2. **Cordon**: Mark each node `unschedulable` (and **Drain** if `drain-enabled=true`)
3. **Apply** (mode-specific):
   - **daemonset**: a single `helm upgrade --install` (run once, up front) sets
     `updateStrategy.type=OnDelete`; the wave step then deletes the kata-deploy pod on each
     node so it is recreated with the new image — other nodes are untouched.
   - **job**: a `helm upgrade --install --set 'job.nodes={wave}'` makes kata-deploy's
     dispatcher install exactly the wave's nodes via short-lived per-node install Jobs.
4. **Wait**: daemonset → each node's kata-deploy pod becomes Ready; job → each node is
   labeled `katacontainers.io/kata-runtime=true` (the install Jobs already completed).
5. **Verify**: run the verification pod on every node in the wave (concurrently) and check
   exit codes.
6. **On Success**: `Uncordon` the verified nodes, proceed to the next wave.
7. **On Failure**: roll back the failed node(s) (daemonset → `helm rollback` + pod restart;
   job → scoped re-upgrade to the previous version), `uncordon`, and the workflow stops.

If verification fails in any wave, the workflow stops immediately, preventing a large
mixed-version fleet (already-verified waves keep the new version).

### When to Use Drain

**Default (drain disabled):** Drain is not required for Kata upgrades. Running Kata
VMs continue using the in-memory binaries. Only new workloads use the upgraded
binaries.

**Optional drain:** Enable drain if you prefer to evict all workloads before any
maintenance operation, or if your organization's operational policies require it:

```bash
# Enable drain when installing the chart
helm install kata-lifecycle-manager oci://ghcr.io/kata-containers/kata-lifecycle-manager-charts/kata-lifecycle-manager \
  --namespace argo \
  --set defaults.drainEnabled=true \
  --set defaults.drainTimeout=600s \
  --set-file defaults.verificationPod=./my-verification-pod.yaml

# Or override at workflow submission time
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0 \
  -p drain-enabled=true \
  -p drain-timeout=600s
```

## Custom Image

By default, the workflow upgrades kata-deploy using the official chart images for the
specified `target-version`. To deploy from a custom image (e.g., your own registry or
a custom build), pass extra `--set` values that override the kata-deploy chart's image
settings.

**At workflow submission (one-off):**

```bash
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0 \
  -p helm-set-values="image.repository=myregistry.io/kata-deploy,image.tag=my-custom-tag"
```

**Baked into the chart (persistent default):**

```bash
helm install kata-lifecycle-manager oci://ghcr.io/kata-containers/kata-lifecycle-manager-charts/kata-lifecycle-manager \
  --namespace argo \
  --set-file defaults.verificationPod=./my-verification-pod.yaml \
  --set 'defaults.helmSetValues=image.repository=myregistry.io/kata-deploy\,image.tag=my-custom-tag'
```

The value uses standard Helm `--set` comma-separated syntax (`key1=val1,key2=val2`).
Any kata-deploy chart value can be overridden this way, not just the image.

## Rollback

**Automatic rollback on verification failure:** If a verification pod fails (non-zero exit),
kata-lifecycle-manager automatically reverts every node upgraded in this workflow run
(including nodes from earlier verified waves):
- **daemonset**: `helm rollback` to the previous release, then restart each upgraded node's
  pod and wait for it to be Ready with the previous version.
- **job**: `helm rollback` would not re-run the dispatcher, so upgraded nodes are reverted by a
  scoped `helm upgrade` back to the previous chart version (reinstalling the old artifacts
  on those nodes).

Then each reverted node is `uncordoned`, annotated `rolled-back`, and the workflow stops.
This ensures nodes are never left in a broken state.

**Manual rollback:** For cases where you need to rollback a successfully upgraded node:

```bash
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  --entrypoint rollback-node \
  -p node-name=worker-1
# job mode: optionally pin the version to reinstall (defaults to the previous
# revision's chart version from `helm history`):
#   -p rollback-version=3.32.0
```

## Monitoring

Check node annotations to monitor upgrade progress:

```bash
kubectl get nodes \
  -L katacontainers.io/kata-lifecycle-manager-status \
  -L katacontainers.io/kata-current-version
```

| Annotation | Description |
|------------|-------------|
| `katacontainers.io/kata-lifecycle-manager-status` | Current upgrade phase |
| `katacontainers.io/kata-current-version` | Version after successful upgrade |

Status values:
- `preparing` - Upgrade starting
- `cordoned` - Node marked `unschedulable`
- `draining` - Draining pods (only if drain-enabled=true)
- `upgrading` - Helm upgrade in progress
- `verifying` - Verification pod running
- `completed` - Upgrade successful
- `rolling-back` - Rollback in progress (automatic on verification failure)
- `rolled-back` - Rollback completed

## How Controlled Rollout Works

The workflow only ever touches the current node (or, with `batch-size>1`, the current
wave's nodes), leaving the rest of the fleet untouched until their turn:

- **daemonset**: `helm upgrade` sets `updateStrategy.type=OnDelete` so pods don't restart
  automatically; the workflow explicitly deletes the kata-deploy pod(s) on the current
  node(s), so Kubernetes recreates only those with the new image.
- **job**: each `helm upgrade` is scoped with `job.nodes={...current node(s)...}`, so
  kata-deploy's dispatcher creates per-node install Jobs only for those nodes.

This ensures that if verification fails later, earlier upgraded nodes are rolled
back together with the failing wave. The workflow stops before touching remaining
nodes.

**Rollback behavior:**
- On verification failure, every node upgraded in this workflow run is reverted to
  the previous version (daemonset → `helm rollback` + pod restart on each upgraded
  node; job → scoped re-upgrade to the previous chart version on those nodes).
- Nodes not yet upgraded in this run are untouched.

## For Projects Using kata-deploy

Any project that uses the kata-deploy Helm chart can install this companion chart
to get upgrade orchestration:

```bash
# Install kata-deploy
helm install kata-deploy oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --namespace kube-system

# Install kata-lifecycle-manager from the published chart (see GitHub Releases)
helm install kata-lifecycle-manager oci://ghcr.io/kata-containers/kata-lifecycle-manager-charts/kata-lifecycle-manager \
  --namespace argo \
  --set-file defaults.verificationPod=./my-verification-pod.yaml

# Trigger upgrade
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  -p target-version=3.27.0
```

**Note:** `target-version` must meet the per-mode minimum (daemonset **3.27.0+**, job **3.32.0+**); the workflow will fail at prerequisites otherwise.

## Testing from a fork

Workflows use the repository owner for GHCR paths so you can test from a fork (e.g. `fidencio/kata-lifecycle-manager`):

1. **Build the workflow image**  
   In your fork: Actions → "Build workflow image" → "Run workflow".  
   This pushes `ghcr.io/<your-username>/lifecycle-manager-utils:latest`.

2. **Release the chart (optional)**  
   Actions → "Release Helm Chart" → "Run workflow", set version (e.g. `0.1.0-dev`).  
   This pushes the chart to `ghcr.io/<your-username>/kata-lifecycle-manager-charts`.

3. **Install from your fork**
   ```bash
   helm install kata-lifecycle-manager \
     oci://ghcr.io/<your-username>/kata-lifecycle-manager-charts/kata-lifecycle-manager \
     --version 0.1.0-dev \
     --set-file defaults.verificationPod=./verification-pod.yaml \
     --set images.utils=ghcr.io/<your-username>/lifecycle-manager-utils:latest \
     --namespace argo
   ```

## Documentation

- [Design Document](docs/design.md) - Architecture and design decisions

## License

Apache License 2.0
