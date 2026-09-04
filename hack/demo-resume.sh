#!/usr/bin/env bash
# Re-enable ArgoCD auto-sync AFTER the Kasten restore has completed and the VM is
# verified. Re-enabling root alone would re-apply demo-vm's automated from Git,
# but we patch both so the state is explicit either way.
set -euo pipefail
for app in root demo-vm; do
  kubectl patch application.argoproj.io "$app" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
  echo "resumed auto-sync: $app"
done
echo "ArgoCD auto-sync resumed (root + demo-vm)."
