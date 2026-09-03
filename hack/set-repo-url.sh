#!/usr/bin/env bash
# Replaces the REPO_URL placeholder everywhere with your actual Git remote.
#   ./hack/set-repo-url.sh https://github.com/you/kubevirt-kasten-gitops.git
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <git-repo-url>"; exit 1; }
cd "$(dirname "$0")/.."
grep -rl 'REPO_URL' apps bootstrap | xargs sed -i.bak "s|REPO_URL|$1|g"
find apps bootstrap -name '*.bak' -delete
echo "Set repoURL to $1"
