# Workflow image (utils)

Single image used by all kata-lifecycle-manager Argo workflow steps. Contains **Helm 4**, **kubectl**, and **jq**.

| Purpose | Tools used |
|---------|------------|
| check-prerequisites, helm-upgrade-global, verify-and-complete-node, print-summary, rollback-node | helm, kubectl |
| get-target-nodes, print-upgrade-plan, prepare-node, cordon-node, drain-node, helm-upgrade (trigger), wait-kata-ready | kubectl |

## Weekly build

The repo builds and pushes this image **weekly**, when its Dockerfile changes on `main`, and on manual dispatch via [Build workflow image](../.github/workflows/build-images.yaml). Pushed image:

- `ghcr.io/kata-containers/lifecycle-manager-utils:latest` (and `:<sha>`)

Platforms: `linux/amd64`, `linux/arm64`, `linux/s390x`, `linux/ppc64le`.

The chart default is this image. To override when installing from the published chart:

```bash
helm install kata-lifecycle-manager oci://ghcr.io/kata-containers/kata-lifecycle-manager-charts/kata-lifecycle-manager \
  --namespace argo \
  --set images.utils=ghcr.io/your-org/your-utils:tag
```

## Building locally

```bash
docker build -t lifecycle-manager-utils images/utils
```
