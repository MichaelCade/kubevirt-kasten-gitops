#!/usr/bin/env bash
# Pause ArgoCD auto-sync BEFORE a destructive delete + Kasten restore, so ArgoCD
# doesn't recreate the VM (and re-mount / re-provision the disk) mid-restore.
#
# app-of-apps gotcha: you must pause the ROOT app first. root's selfHeal manages
# the demo-vm Application from Git (which has automated:{prune,selfHeal}), so
# pausing only demo-vm gets reverted within seconds and the VM comes back.
set -euo pipefail
for app in root demo-vm; do
  kubectl patch application.argoproj.io "$app" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  echo "paused auto-sync: $app"
done
echo "ArgoCD auto-sync paused (root + demo-vm). Safe to delete + restore from Kasten."
