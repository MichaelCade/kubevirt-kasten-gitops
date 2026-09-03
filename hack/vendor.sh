#!/usr/bin/env bash
# Vendors the pinned KubeVirt + CDI release manifests into the repo, so ArgoCD has
# a single Git source of truth (ArgoCD cannot source a raw GitHub release URL).
# Re-run to bump versions, then commit the diff - that IS your upgrade PR.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pin explicitly, or leave unset to resolve upstream "latest" and print what you got.
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-$(curl -sfL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
CDI_VERSION="${CDI_VERSION:-$(basename "$(curl -sfL -o /dev/null -w '%{url_effective}' https://github.com/kubevirt/containerized-data-importer/releases/latest)")}"

echo "==> KubeVirt ${KUBEVIRT_VERSION}"
curl -sfL -o infra/kubevirt/operator/kubevirt-operator.yaml \
  "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

echo "==> CDI ${CDI_VERSION}"
curl -sfL -o infra/cdi/operator/cdi-operator.yaml \
  "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"

cat > VERSIONS.txt <<EOT
kubevirt=${KUBEVIRT_VERSION}
cdi=${CDI_VERSION}
EOT

echo
echo "Pinned in VERSIONS.txt. Check CDI compatibility with your KubeVirt version:"
echo "  https://github.com/kubevirt/containerized-data-importer/releases"
echo "Then: git add -A && git commit -m 'vendor kubevirt ${KUBEVIRT_VERSION} / cdi ${CDI_VERSION}'"
