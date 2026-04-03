# Kata Lifecycle Manager Helm Chart

[![E2E Tests](https://github.com/kata-containers/lifecycle-manager/actions/workflows/e2e-tests.yaml/badge.svg?branch=main)](https://github.com/kata-containers/lifecycle-manager/actions/workflows/e2e-tests.yaml)

Argo Workflows-based lifecycle management for Kata Containers.

This chart installs a namespace-scoped `WorkflowTemplate` that performs controlled,
node-by-node upgrades of kata-deploy with verification and automatic rollback on failure.

## Prerequisites

- Kubernetes cluster with **kata-deploy installed via Helm** (chart **3.27.0 or higher** required; the workflow uses `helm upgrade --install` and relies on the kata-deploy chart to set DaemonSet `updateStrategy.type=OnDelete`)
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

### 3. Sequential Upgrade Behavior

Nodes are upgraded **sequentially** (one at a time) to ensure fleet consistency.
If any node fails verification, the workflow stops immediately and that node is
rolled back. This prevents ending up with a mixed fleet where some nodes have
the new version and others have the old version.

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `argoNamespace` | Namespace for Argo resources | `argo` |
| `defaults.helmRelease` | kata-deploy Helm release name | `kata-deploy` |
| `defaults.helmNamespace` | kata-deploy namespace | `kube-system` |
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
| `node-selector` | Label selector for nodes |
| `node-taint-key` | Taint key for node selection |
| `node-taint-value` | Taint value filter |
| `verification-namespace` | Namespace for verification pods |
| `verification-pod` | Pod YAML with placeholders |
| `drain-enabled` | Whether to drain nodes before upgrade |
| `drain-timeout` | Timeout for drain operation |
| `helm-set-values` | Extra `--set` values for `helm upgrade` (see [Custom Image](#custom-image)) |

## Deploy Flow

For each node selected by the node-selector label:

1. **Prepare**: Annotate node with deploy status
2. **Cordon**: Mark node as `unschedulable`
3. **Drain** (optional): Evict pods if `drain-enabled=true`
4. **Helm Upgrade**: Run `helm upgrade --install` with `updateStrategy.type=OnDelete` (kata-deploy chart 3.27.0+ applies this)
   - This updates the DaemonSet spec but does NOT restart pods automatically
5. **Trigger Pod Restart**: Delete the kata-deploy pod on THIS node only
   - This triggers recreation with the new image on just this node
6. **Wait**: Wait for new kata-deploy pod to be ready
7. **Verify**: Run verification pod and check exit code
8. **On Success**: `Uncordon` node, proceed to next node
9. **On Failure**: Automatic rollback (helm rollback + pod restart), `uncordon`, workflow stops

**True node-by-node control**: By using `updateStrategy: OnDelete`, the workflow
ensures that only the current node's pod restarts. Other nodes continue running
the previous version until explicitly upgraded.

Nodes are processed **sequentially** (one at a time). If verification fails on any node,
the workflow stops immediately, preventing a mixed-version fleet.

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

**Automatic rollback on verification failure:** If the verification pod fails (non-zero exit),
kata-lifecycle-manager automatically:
1. Runs `helm rollback` to revert to the previous Helm release
2. Waits for kata-deploy DaemonSet to be ready with the previous version
3. `Uncordons` the node
4. Annotates the node with `rolled-back` status

This ensures nodes are never left in a broken state.

**Manual rollback:** For cases where you need to rollback a successfully upgraded node:

```bash
argo submit -n argo --from workflowtemplate/kata-lifecycle-manager \
  --entrypoint rollback-node \
  -p node-name=worker-1
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

## How Node-by-Node Control Works

The workflow uses `updateStrategy.type=OnDelete` to achieve true node-by-node control:

1. **Helm upgrade** updates the DaemonSet spec but pods don't restart automatically
2. The workflow **explicitly deletes** the kata-deploy pod on the current node
3. Kubernetes recreates the pod with the new image on just that node
4. Other nodes continue running the previous version until their turn

This ensures that if verification fails on Node B, Node A is still running the
new version (verified working) while the workflow stops. No automatic cluster-wide
rollback occurs unless explicitly triggered.

**Rollback behavior:**
- On verification failure, `helm rollback` reverts the DaemonSet spec
- The pod on the failed node is deleted to restart with the previous version
- Already-verified nodes continue running the new version (their pods weren't touched)

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

**Note:** `target-version` must be **3.27.0 or higher**; the workflow will fail at prerequisites otherwise.

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
