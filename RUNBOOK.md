# Runbook — KubeVirt + ArgoCD + Veeam Kasten on Talos with Rook-Ceph

## Starting point

You already have: Talos cluster (5 nodes), Rook-Ceph, Veeam Kasten, ArgoCD. This repo adds KubeVirt, a GitOps-deployed VM, and the Kasten `Profile`/`Policy` that protects it — as ArgoCD Applications.

**Not managed by this repo:** Rook-Ceph, and your existing Kasten install. Kasten stays exactly where it is; only its *configuration* comes from Git.

## Verdict: yes, this works

| Piece | Object | In Git? |
|---|---|---|
| KubeVirt | operator manifest + `KubeVirt` CR | yes |
| CDI | operator manifest + `CDI` CR | yes |
| The VM | `VirtualMachine` + `DataVolume` | yes |
| Backup policy | `Policy` (`config.kio.kasten.io/v1alpha1`) | yes |
| Backup target | `Profile` (`config.kio.kasten.io/v1alpha1`) | yes (secret out-of-band) |
| Snapshot class | annotated `VolumeSnapshotClass` | yes |

**Two caveats before you demo it.**

1. **Support status.** Kasten *officially* supports the OpenShift Virtualization and SUSE Virtualization (Harvester) flavours of KubeVirt. Upstream KubeVirt on vanilla Kubernetes is not on the supported list. It works — discovery keys off `kubevirt.io/v1 VirtualMachine` and `cdi.kubevirt.io/v1beta1 DataVolume`, nothing OpenShift-specific — but if this is customer-facing, say "upstream KubeVirt, not a supported configuration" out loud.

2. **Kasten's `Policy`/`Profile` are not CRDs.** They're served by an aggregated extension API server, so the `config.kio.kasten.io` group only exists while Kasten is healthy. Yours already is, so this is mostly a non-issue for you — but keep them in their own Application (as this repo does) so a Kasten restart doesn't wedge an unrelated sync.

Rook-Ceph is the right storage layer here, and you've already solved the hardest prerequisite: real CSI VolumeSnapshot support. Kasten's Generic Storage Backup fallback explicitly **does not work for virtual machines**, so a snapshot-capable CSI isn't optional.

---

## Step 1 — Check the Talos nodes can host VMs

### Do NOT use the node allocatable check before installing KubeVirt

```bash
# WRONG as a pre-install check — always returns null
kubectl get nodes -o json | jq '.items[].status.allocatable["devices.kubevirt.io/kvm"]'
```

`devices.kubevirt.io/kvm` is advertised by a device plugin that lives inside KubeVirt's own `virt-handler` DaemonSet. Before KubeVirt is installed nothing advertises it, so every node returns `null` regardless of your BIOS. This check is only meaningful **after** Step 5.

### Check at the OS level instead

```bash
for N in <node1-ip> <node2-ip> <node3-ip> <node4-ip> <node5-ip>; do
  echo "== $N"
  # CPU virtualization extensions: vmx = Intel VT-x, svm = AMD-V
  talosctl -n $N read /proc/cpuinfo | grep -oE '\b(vmx|svm)\b' | sort -u
  # does the kernel actually expose the device?
  talosctl -n $N list /dev | grep -x kvm
done
```

Output from both = you're fine. Empty = virtualisation is off in BIOS, or nested virt is off on a parent hypervisor. Note a widely-copied blog snippet uses `grep -c "vmx|svm"` — that's broken, it needs `-E`.

**There is nothing to install for KVM on Talos.** `CONFIG_KVM`, `CONFIG_KVM_INTEL` and `CONFIG_KVM_AMD` are compiled `=y` into the Talos kernel — builtins, not modules. So:

- Do **not** add `kvm` / `kvm_intel` / `kvm_amd` to `machine.kernel.modules`. There's no `.ko` to load; the module loader will just fail.
- There is no `siderolabs/kvm` system extension. Don't go looking for one.
- Builtins never appear in `lsmod`, so an empty `lsmod | grep kvm` means nothing.

You can prove it if you want:

```bash
talosctl -n $NODE read /proc/config.gz | zgrep -E '^CONFIG_KVM(_INTEL|_AMD|_X86)?='
```

### Check SELinux state — the one real Talos-specific trap

```bash
talosctl version --nodes $NODE
talosctl -n $NODE get SecurityState
```

Talos 1.9.0 and 1.9.1 mounted `selinuxfs` without loading a policy. KubeVirt only tests whether `/sys/fs/selinux` exists, concluded SELinux was active, and `virt-handler` then died with:

```
could not retrieve pid N selinux label: getxattr /proc/N/attr/current: operation not supported
```

Fixed in **Talos 1.9.2** ([PR #10084](https://github.com/siderolabs/talos/pull/10084)). From 1.10 onward SELinux is genuinely enabled with a real policy in **permissive** mode, so the failure doesn't apply. Two consequences:

- On 1.9.0/1.9.1, upgrade before anything else. The KubeVirt-side issue was auto-closed as stale — there is no workaround from that end.
- Leave SELinux **permissive**. Don't set `enforcing=1` — Sidero only tests enforcing with Flannel, and system extensions don't support it.

### Pod Security

Talos enforces the `baseline` Pod Security profile cluster-wide by default, and `virt-launcher` needs privileged. The `demo-vms` namespace in this repo is labelled accordingly. KubeVirt normally labels its own namespace, but setting it explicitly removes a class of "VM stuck in Scheduling".

## Step 2 — Check your Rook StorageClasses and snapshot class

```bash
kubectl get sc
kubectl get volumesnapshotclass
```

**a. Your RBD StorageClass name.** This repo assumes `ceph-block` (the Rook default). If yours differs, update `workloads/fedora-vm/virtualmachine.yaml` and `infra/cdi/cr/cdi.yaml`.

**b. Exactly one annotated VolumeSnapshotClass per provisioner.**

```bash
kubectl get volumesnapshotclass -o json | jq -r \
  '.items[] | [.metadata.name, .driver, (.metadata.annotations["k10.kasten.io/is-snapshot-class"] // "-")] | @tsv'
```

If you already have a `csi-rbdplugin-snapclass`, **delete `infra/rook-ceph/volumesnapshotclass-rbd.yaml` from this repo** and annotate the existing one:

```bash
kubectl annotate volumesnapshotclass csi-rbdplugin-snapclass k10.kasten.io/is-snapshot-class=true
```

Zero annotated classes, or two for the same driver, and every snapshot operation fails. `deletionPolicy` must be `Delete`.

Optionally pin per-StorageClass instead:

```bash
kubectl annotate storageclass ceph-block k10.kasten.io/volume-snapshot-class=csi-rbdplugin-snapclass
```

Sanity-check the whole storage path with Kasten's preflight tool:

```bash
curl -s https://docs.kasten.io/downloads/9.0.4/tools/k10_primer.sh | bash
curl -s https://docs.kasten.io/downloads/9.0.4/tools/k10_primer.sh | bash /dev/stdin csi -s ceph-block
```

## Step 3 — Prepare the repo

```bash
git clone <your-empty-repo> && cd kubevirt-kasten-gitops
cp -r /path/to/this/repo/* .

./hack/vendor.sh                                    # pull pinned KubeVirt + CDI manifests
./hack/set-repo-url.sh https://github.com/you/kubevirt-kasten-gitops.git
```

Edit before committing:

- `workloads/fedora-vm/virtualmachine.yaml` → your SSH public key, and `storageClassName` if not `ceph-block`
- `infra/cdi/cr/cdi.yaml` → `scratchSpaceStorageClass`
- `kasten/config/profile-s3.yaml` → bucket, region, endpoint
- `infra/rook-ceph/volumesnapshotclass-rbd.yaml` → delete if you already have one (Step 2)

```bash
git add -A && git commit -m "initial" && git push
```

## Step 4 — Create the Kasten S3 secret

Not in Git. If you already have a Location Profile you're happy with, skip this and point `kasten/config/policy-vm.yaml` at its name instead.

```bash
kubectl create secret generic k10-s3-secret --namespace kasten-io \
  --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id="$AWS_ACCESS_KEY_ID" \
  --from-literal=aws_secret_access_key="$AWS_SECRET_ACCESS_KEY"
```

Worth wiring up Sealed Secrets / External Secrets / SOPS if the audience cares about secret handling — it's the one thing here that isn't in Git, and someone always asks.

## Step 5 — Bootstrap

One imperative command, then never again:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

Sync waves: snapshot class (0) → KubeVirt operator (1) → KubeVirt CR + CDI (2) → Kasten Profile/Policy (3) → the VM (4).

```bash
kubectl get applications -n argocd -w
```

## Step 6 — Verify each layer

**Now** the allocatable check from Step 1 becomes meaningful:

```bash
kubectl get nodes -o json | jq '.items[] | {name: .metadata.name, kvm: .status.allocatable["devices.kubevirt.io/kvm"]}'
# expect "1k" or similar on every node running virt-handler
kubectl get pods -n kubevirt -l kubevirt.io=virt-handler
```

```bash
# KubeVirt
kubectl get kubevirt -n kubevirt kubevirt -o jsonpath='{.status.phase}'   # Deployed
kubectl get cdi cdi -o jsonpath='{.status.phase}'                          # Deployed

# The VM (image import takes several minutes)
kubectl get dv -n demo-vms -w        # Succeeded
kubectl get pvc -n demo-vms          # VOLUMEMODE Block, ACCESS MODES RWX
kubectl get vmi -n demo-vms -o wide  # Running

# Kasten picked up the config
kubectl get profiles.config.kio.kasten.io -n kasten-io
kubectl get policies.config.kio.kasten.io -n kasten-io
```

## Step 7 — Confirm the VM is application-consistent

This is the detail that separates a good demo from a hand-wave. Kasten freezes the guest filesystem via `qemu-guest-agent` before snapshotting — on Windows guests it drives VSS instead. The cloud-init in this repo installs and enables it.

```bash
# agent visible to KubeVirt?
kubectl get vmi -n demo-vms fedora-vm -o jsonpath='{.status.conditions}' | jq   # AgentConnected=True

# after a backup runs:
kubectl get restorepoints.apps.kio.kasten.io -n demo-vms -o yaml | grep -A3 vmInfo
#   snapshotConsistency: ApplicationConsistent
```

If the agent is missing, Kasten falls back to crash-consistent, records an exception, and **does not fail the job** — easy to miss. Tuning knobs, if you need them (Helm values on your existing install):

```bash
kubeVirtVMs.snapshot.unfreezeTimeout=3m     # default 5m
limiter.vmSnapshotsPerCluster=2             # default 1 VM frozen at a time
```

Per-VM opt-out:

```bash
kubectl annotate virtualmachine -n demo-vms fedora-vm k10.kasten.io/freezeVM=false
```

---

## Why RBD + Block + RWX

The VM's root disk uses `volumeMode: Block`, `accessModes: [ReadWriteMany]`, `storageClassName: ceph-block`. All three matter:

- Ceph RBD supports multi-node access **only** in Block volumeMode — an RWX RBD PVC in Filesystem mode will not bind
- KubeVirt LiveMigration requires RWX
- Block mode hands the guest the raw device, skipping a pointless filesystem layer

Don't use CephFS for VM root disks. CephFS is the right answer for RWX *filesystem* PVCs elsewhere; RBD is the right pool for VM disks.

CDI scratch space is always a **Filesystem** PVC even when the target disk is Block — hence the separate `scratchSpaceStorageClass`.

---

## Gotchas, collected

| Symptom | Cause | Fix |
|---|---|---|
| `devices.kubevirt.io/kvm: null` before install | Device plugin ships with virt-handler | Not a fault — check `/dev/kvm` via talosctl instead |
| virt-handler `getxattr ... operation not supported` | Talos 1.9.0/1.9.1 selinuxfs bug | Upgrade to ≥1.9.2; keep SELinux permissive |
| `machine.kernel.modules: [kvm]` fails | KVM is a kernel builtin on Talos | Remove it; nothing to load |
| VM stuck Scheduling | Talos baseline Pod Security | Namespace label `pod-security.kubernetes.io/enforce: privileged` |
| Snapshot ops fail | Zero, or >1, annotated VolumeSnapshotClass per provisioner | Exactly one gets `k10.kasten.io/is-snapshot-class=true` |
| RWX PVC never binds | RBD in Filesystem mode | `volumeMode: Block` |
| `no matches for kind "Policy"` | Aggregated API unavailable | `kubectl get apiservice v1alpha1.config.kio.kasten.io` |
| ArgoCD keeps re-syncing the VM | KubeVirt writes `/status`, CDI mutates the PVC | `ignoreDifferences` (already in this repo) |
| Backup is crash-consistent | No `qemu-guest-agent` in the guest | Install + enable in cloud-init |
| CDI import pod OOMKilled | Default CDI limits too low | `podResourceRequirements` (already raised here) |
| NFS-backed PVC hangs | Talos has no `rpc.statd` | `nolock` mount option (only if you use NFS anywhere) |

## Sources

- [Install KubeVirt on Talos — Sidero docs](https://docs.siderolabs.com/talos/v1.11/advanced-guides/install-kubevirt)
- [Talos SELinux docs](https://docs.siderolabs.com/talos/v1.11/security/selinux) · [talos#10083](https://github.com/siderolabs/talos/issues/10083) · [talos#10084](https://github.com/siderolabs/talos/pull/10084) · [discussion #7793](https://github.com/siderolabs/talos/discussions/7793)
- [Veeam Kasten — VM Protection](https://docs.kasten.io/latest/usage/vm_protection)
- [Veeam Kasten — Policies API](https://docs.kasten.io/latest/api/policies) · [Profiles API](https://docs.kasten.io/latest/api/profiles)
- [Veeam Kasten — Storage Integration](https://docs.kasten.io/latest/install/storage) · [Generic Storage Backup](https://docs.kasten.io/latest/install/generic)
- [Rook — Ceph CSI Snapshots](https://rook.io/docs/rook/latest/Storage-Configuration/Ceph-CSI/ceph-csi-snapshot/)
- [KubeVirt — Live Migration](https://kubevirt.io/user-guide/compute/live_migration/)
