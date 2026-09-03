# kubevirt-kasten-gitops

A demo: a KubeVirt VM deployed by ArgoCD on Talos + Rook-Ceph, protected by Veeam Kasten — where the backup policy is itself deployed by ArgoCD.

**Assumes you already have:** Talos cluster, Rook-Ceph, Veeam Kasten, ArgoCD.
**This repo adds:** KubeVirt, CDI, one VM, and Kasten's `Profile` + `Policy`.
**Does not touch:** your Rook-Ceph or your Kasten install.

- **[RUNBOOK.md](RUNBOOK.md)** — build it, step by step, with the gotchas
- **[DEMO-SCRIPT.md](DEMO-SCRIPT.md)** — what to say, what to break, what to restore

## Layout

```
bootstrap/root-app.yaml          app-of-apps — the one thing you apply by hand
apps/                            ArgoCD Applications, ordered by sync wave
  00-storage-snapclass.yaml      wave 0  annotated VolumeSnapshotClass for Kasten
  10-kubevirt-operator.yaml      wave 1  KubeVirt operator
  20-kubevirt-cr.yaml            wave 2  KubeVirt CR
  21-cdi.yaml                    wave 2  CDI operator + CR
  30-kasten-config.yaml          wave 3  Profile + Policy
  40-demo-vm.yaml                wave 4  the VM
infra/rook-ceph/                 RBD VolumeSnapshotClass (+ optional CephFS one)
infra/kubevirt/operator/         vendored release manifest (hack/vendor.sh)
infra/kubevirt/cr/               KubeVirt CR
infra/cdi/                       vendored operator + CDI CR
kasten/config/                   Profile (S3) + two VM backup Policy variants
workloads/fedora-vm/             Namespace, VirtualMachine (RBD block RWX), Service
talos/kubevirt-patch.yaml        optional bridge patch for Multus-attached VMs
hack/vendor.sh                   pull pinned KubeVirt/CDI manifests
hack/set-repo-url.sh             swap the REPO_URL placeholder for your remote
```

## Quick start

```bash
./hack/vendor.sh
./hack/set-repo-url.sh https://github.com/you/kubevirt-kasten-gitops.git

# check these against the live cluster before committing:
talosctl -n <node> list /dev | grep -x kvm   # is virtualization on? (NOT the node allocatable)
kubectl get sc                               # is your RBD class called ceph-block?
kubectl get volumesnapshotclass              # already have csi-rbdplugin-snapclass?

# edit: SSH key in workloads/fedora-vm/virtualmachine.yaml
#       bucket in kasten/config/profile-s3.yaml
git add -A && git commit -m init && git push

kubectl create secret generic k10-s3-secret -n kasten-io --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id=... --from-literal=aws_secret_access_key=...

kubectl apply -f bootstrap/root-app.yaml
```

## Five things that will bite you

1. **`devices.kubevirt.io/kvm` is `null` until KubeVirt is installed.** The device plugin ships inside `virt-handler`. Before install it tells you nothing about your BIOS — check `/dev/kvm` via `talosctl` instead.
2. **KVM is a kernel builtin on Talos.** Don't add `kvm`/`kvm_intel`/`kvm_amd` to `machine.kernel.modules`; there's no module to load, and no `siderolabs/kvm` extension exists.
3. **Exactly one annotated VolumeSnapshotClass per provisioner.** Zero, or two for the same driver, and every Kasten snapshot fails. If you already have `csi-rbdplugin-snapclass`, delete this repo's copy and annotate yours.
4. **RBD needs `volumeMode: Block` for RWX.** Ceph RBD only does multi-node access in block mode, and LiveMigration needs RWX. An RWX RBD PVC in Filesystem mode never binds.
5. **Upstream KubeVirt is not an officially supported Kasten configuration** — OpenShift Virtualization and SUSE Virtualization (Harvester) are. It works; say so anyway.

Also worth confirming: you're on **Talos ≥ 1.9.2**. 1.9.0/1.9.1 mounted `selinuxfs` with no policy loaded, which killed `virt-handler` outright. Keep SELinux permissive; don't set `enforcing=1`.

## Versions

Nothing here installs Kasten or Rook. KubeVirt (**v1.9.0** at time of writing) and CDI are resolved to upstream latest by `hack/vendor.sh`, which records what it picked in `VERSIONS.txt` — set `KUBEVIRT_VERSION` / `CDI_VERSION` to pin them. Check the [CDI release notes](https://github.com/kubevirt/containerized-data-importer/releases) for KubeVirt compatibility before bumping.
