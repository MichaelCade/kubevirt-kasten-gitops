# Demo script — "The VM is just another Git commit"

**Runtime:** ~20 minutes live, ~12 if you pre-warm the image import.
**One-liner:** A virtual machine, its storage, and its backup policy are all declared in Git. Nobody clicked anything.

**Pre-warm before you present:** let the CDI image import finish and the VM boot. It takes several minutes and is not interesting to watch. Have the VM Running and one backup already completed so you have a restore point in hand.

---

## Act 1 — The setup (2 min)

Show two windows: your Git repo, and the ArgoCD UI with the app-of-apps tree fully green.

> "Six ArgoCD Applications. A snapshot class, KubeVirt, CDI, Kasten's configuration, and one virtual machine. Ceph and Kasten were already here. I ran exactly one imperative command to get the rest — `kubectl apply -f bootstrap/root-app.yaml`. Everything after that came from Git."

Click into `demo-vm`. Point at the resource tree: `VirtualMachine` → `DataVolume` → `PersistentVolumeClaim`.

> "That's a Fedora VM. To Kubernetes it's a custom resource. To ArgoCD it's just another object to reconcile. Which means it gets pull requests, code review, and rollback like anything else."

Show it's real:

```bash
kubectl get vmi -n demo-vms -o wide
kubectl virt console fedora-vm -n demo-vms
```

Log in, `curl localhost`, show the web page and `/srv/demo/created-at.txt`.

## Act 2 — GitOps actually drives it (3 min)

Prove reconciliation rather than asserting it. First type something into the guest so you can show it's gone:

```bash
# inside the guest
echo "irreplaceable business data" | sudo tee /srv/demo/important.txt
```

Then delete the VM out from under ArgoCD:

```bash
kubectl delete vm fedora-vm -n demo-vms
```

Watch ArgoCD go OutOfSync and self-heal it back. Then make the point:

> "Notice what it recreated: the VM definition. Not the data. The DataVolume was pruned with it and the disk gets rebuilt from the source image. Git gives you back the *shape* of the VM. It does not give you back what was inside it. That's the gap."

## Act 3 — Protection, also from Git (4 min)

Open `kasten/config/policy-vm.yaml` in the editor. Read the selector out loud:

```yaml
selector:
  matchExpressions:
    - key: k10.kasten.io/virtualMachineRef
      operator: In
      values: ["demo-vms/fedora-vm"]
```

> "That's the whole backup policy. Hourly snapshot, daily export to object storage, 24 hourly and 7 daily restore points. It's a Kubernetes object in the same repo as the VM. The person who ships the VM ships its protection in the same pull request."

Show it landed:

```bash
kubectl get policies.config.kio.kasten.io -n kasten-io
```

Switch to the Kasten dashboard. Show the policy Kasten built from that YAML — same thing, rendered.

> "I never opened this UI to create that. ArgoCD did. If someone edits it here, ArgoCD reverts it on the next sync — Git is the only way to change protection."

Optional strong beat: edit the policy retention in the Kasten UI, then let ArgoCD self-heal it back.

## Act 4 — Application consistency (2 min)

The bit that separates VM backup from "snapshot the PVC and hope."

```bash
kubectl get restorepoints.apps.kio.kasten.io -n demo-vms -o yaml | grep -A3 vmInfo
```

> `snapshotConsistency: ApplicationConsistent`

> "Before Kasten took that snapshot it talked to the QEMU guest agent inside Fedora and froze the filesystem — on Windows guests it drives VSS instead. Then it snapshotted, then it thawed. That's a VM-consistent restore point, not a crash-consistent one. The guest agent was installed by the cloud-init in the same Git repo."

Point at what Kasten captured without being told: VirtualMachine, VirtualMachineInstance, instance types and preferences, DataVolumes, PVCs, StorageClasses, ConfigMaps, Secrets, ServiceAccounts, network attachments. No blueprint written by hand.

## Act 5 — Break it, restore it (5 min)

The payoff. Do real damage:

```bash
# inside the guest
sudo rm -rf /srv/demo /var/www/html/index.html
sudo systemctl stop httpd
```

Show the page is gone. Then destroy the whole thing:

```bash
kubectl delete vm fedora-vm -n demo-vms
kubectl delete dv fedora-vm-root -n demo-vms
kubectl get pvc -n demo-vms      # empty
```

> "The VM is gone. The disk is gone. ArgoCD will happily rebuild the VM — from a stock Fedora image, with none of my data."

Restore from Kasten (dashboard → Applications → `fedora-vm` → Restore → pick the restore point). Then:

```bash
kubectl get vmi -n demo-vms -w
kubectl virt console fedora-vm -n demo-vms
cat /srv/demo/important.txt
curl localhost
```

> "Same VM. Same disk contents. Same file I typed five minutes ago."

## Act 6 — The close (2 min)

Two sentences, then stop talking:

> "Git gave me the VM's definition. Kasten gave me its data. Neither one alone is a recovery story — you need both, and both were declared in the same repository."

If you want a second beat, show the label-based policy:

```bash
kubectl label vm new-vm -n demo-vms backup=hourly
```

> "Any VM that carries this label self-enrols into protection. Developers don't file backup tickets — they add a label to their manifest."

---

## Q&A ammunition

**"Is upstream KubeVirt supported?"**
Kasten officially supports OpenShift Virtualization and SUSE Virtualization (Harvester). This demo is upstream KubeVirt on Talos — it works, it's not a supported configuration. Say it before someone else does.

**"Why not just use `VirtualMachineSnapshot`?"**
KubeVirt's own snapshot CR is in-cluster only — same storage, same cluster, same failure domain. It's a rollback tool, not a backup. Kasten exports off-cluster to object storage with retention and immutability options.

**"Can I put the backup in the app's own repo instead?"**
Yes. The Policy is namespaced in `kasten-io` but nothing stops you templating it from the app chart. There's also a pre-sync-hook pattern — trigger an on-demand Kasten backup before an ArgoCD sync, so every deploy is preceded by a restore point.

**"What about the secrets?"**
The S3 credential is the one thing not in Git here. Sealed Secrets, External Secrets Operator, or SOPS all solve it — mention that you deliberately left it out rather than being caught on it.

**"Storage requirements?"**
CSI with VolumeSnapshot support is mandatory for VMs — Kasten's Generic Storage Backup fallback explicitly does not work for virtual machines, so `local-path` and friends are out. Rook-Ceph RBD is a good answer. Worth showing the disk while you're at it: `volumeMode: Block`, `ReadWriteMany`, `ceph-block`. RBD only does multi-node access in block mode, and RWX is what makes live migration possible — so the same choice that lets you migrate the VM is the one that lets Kasten snapshot it.

**"Can I live-migrate it too?"**
Yes, and it's a good bonus beat: `kubectl virt migrate fedora-vm -n demo-vms`, then watch `kubectl get vmi -n demo-vms -o wide` change node while the web page stays up. That works *because* the disk is RWX block on Ceph.

---

## Failure recovery, live

| It broke | Do this |
|---|---|
| VM won't start | `kubectl describe vmi -n demo-vms fedora-vm` — usually PSA or the KVM device |
| virt-handler CrashLooping | Check Talos version ≥ 1.9.2 and SELinux permissive |
| Image import hangs | `kubectl logs -n demo-vms -l cdi.kubevirt.io=importer` — often the mirror, not you |
| Restore stuck `WaitingForVolumeBinding` | Known race, fixed in recent Kasten; retry the restore |
| Snapshot fails instantly | Check exactly one annotated VolumeSnapshotClass for `rook-ceph.rbd.csi.ceph.com` |
| Nothing works | You have the pre-warmed restore point and a screen recording. Right? |
