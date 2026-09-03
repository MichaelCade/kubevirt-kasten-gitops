#!/usr/bin/env bash
# One-time seed of the VM boot disk (workloads/fedora-vm/pvc.yaml).
#
# WHY THIS EXISTS
# On this cluster CDI's importer runs as a non-root pod (UID 107, all caps
# dropped) while Rook's RBD *block* device is root:root 0600 - fsGroupPolicy=File
# never applies a group to block volumes - so the importer cannot open it. The
# VM's own virt-launcher IS privileged and reads the block device fine, so we
# seed the raw device once with a privileged Job, then boot the VM from the PVC.
# Same "declared in Git, contents supplied out-of-band" pattern as the S3 secret.
#
# Re-runnable: deletes any previous seed Job first. Safe to run while the VM is
# Halted (it must NOT be running - the disk is RWX but qemu-img needs exclusive
# use for the write).
set -euo pipefail

NS="${NS:-demo-vms}"
PVC="${PVC:-fedora-vm-root}"
IMAGE_URL="${IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2}"
TOOL_IMAGE="${TOOL_IMAGE:-alpine:3.20}"

echo "==> Seeding $NS/$PVC from $IMAGE_URL"
kubectl -n "$NS" delete job seed-boot-disk --ignore-not-found

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: seed-boot-disk
  namespace: ${NS}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: seed
          image: ${TOOL_IMAGE}
          securityContext:
            privileged: true
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              apk add --no-cache qemu-img curl
              echo "downloading image..."
              curl -fL --retry 3 -o /work/img "${IMAGE_URL}"
              echo "writing to block device /dev/bootdisk..."
              qemu-img convert -p -O raw /work/img /dev/bootdisk
              echo "seed complete"
          volumeDevices:
            - name: bootdisk
              devicePath: /dev/bootdisk
          volumeMounts:
            - name: work
              mountPath: /work
      volumes:
        - name: bootdisk
          persistentVolumeClaim:
            claimName: ${PVC}
        - name: work
          emptyDir:
            sizeLimit: 2Gi
EOF

echo "==> Waiting for seed to complete (downloads + converts, a few minutes)..."
kubectl -n "$NS" wait --for=condition=complete job/seed-boot-disk --timeout=600s
kubectl -n "$NS" logs job/seed-boot-disk --tail=5
echo "==> Done. Flip the VM to runStrategy: Always and let ArgoCD boot it."
