# Phase 2 (Advanced): Soft-Slicing One Quadra VPU Across Multiple Pods

This guide builds on the main README and shows how to run multiple Kubernetes pods against a
single NETINT Quadra T1U VPU on Akamai (Linode) Cloud by sharing host device nodes and `/dev/shm`.

> Prerequisite: You’ve already gone through the main guide at the repo root (`README.md`) and understand:
> - `netint.ca/Quadra` vs `netint.ca/ASIC`
> - One-pod-per-VPU scheduling behavior
> - The “one pod, many sessions” best-practice model

## Phase 1: Host Preparation

Run these commands directly on the Akamai VM that has the Quadra card attached:

```bash
# 1. Locate the VPU device nodes
ls /dev/nvme*

# 2. Locate FFmpeg
which ffmpeg  # Expected: /usr/local/bin/ffmpeg

# 3. Verify Quadra encoders
ffmpeg -encoders | grep ni_quadra
```

You should see:
- /dev/nvme0 and /dev/nvme0n1 in the ls output.
- ffmpeg in a known path (for example /usr/local/bin/ffmpeg).

Entries like h264_ni_quadra_enc and h265_ni_quadra_enc in the encoder list.

If those three checks pass, the host knows about the card and FFmpeg knows how to use it.
From there, Kubernetes is a delivery mechanism, not a magic fixer.

## Phase 2: VPU Logic Script (vpu-guard.sh via ConfigMap)

The vpu-guard.sh script centralizes the work each pod does when it wants to talk to the VPU:
- Initializes the Quadra device with -init_hw_device.
- Uploads a CPU-generated test source to the VPU.
- Builds a hardware-based ABR ladder (for example 1080p → 720p / 480p / 360p) with ni_quadra_scale.
- Encodes each rung using the Quadra hardware encoders.

The full script lives in vpu-guard.sh.

Create a ConfigMap from this file:

```bash
kubectl create configmap vpu-scripts \
  --from-file=vpu-guard.sh=./vpu-guard.sh
```

Each pod in the shared pool will mount and execute vpu-guard.sh as its entrypoint.

## Phase 3: Shared VPU Deployment (vpu-shared-pool)

The soft-slicing pattern relies on three key mounts into every pod:
- The Quadra namespace device node (for example /dev/nvme0n1).
- The Quadra controller device node (for example /dev/nvme0).
- The host’s shared memory (/dev/shm).

This is expressed as a Kubernetes Deployment called vpu-shared-pool:
- spec.replicas: 4 gives you four independent pods (tune as needed).
- Each pod:
  - Runs a Quadra-ready FFmpeg container image.
  - Is privileged: true so it can perform PCIe/IOCTL operations.
  - Mounts /dev/nvme0, /dev/nvme0n1, and /dev/shm from the host.
  - Mounts vpu-guard.sh from the vpu-scripts ConfigMap and runs it as its command.

The full manifest is in phase2-shared-vpu-deploy.yaml. Apply it with:

```bash
kubectl apply -f phase2-shared-vpu-deploy.yaml
```

From Kubernetes’ perspective, this is just a deployment with multiple pods; no special extended
resources are requested in the manifest. From the host’s perspective, you now have several FFmpeg
processes, each running its own ABR ladder, all using the same Quadra VPU device behind the scenes.

## Phase 4: Verification
Once the deployment is up, it’s worth validating that:
- All pods are healthy.
- Work is actually happening inside them.
- The VPU is doing meaningful work, not just idling.
- The same VPU device node is opened by multiple processes.

### 4.1 Pod health
```bash
kubectl get pods -l app=vpu-worker
```

You should see all pods in STATUS: Running with RESTARTS: 0 once they’re stable.

### 4.2 Encoding activity
```bash
kubectl logs -l app=vpu-worker --tail=20
```

You should see frame= progress lines and h264_ni_quadra_enc usage in the logs.

### 4.3 Hardware utilization on the host
```bash
ni_rsrc_mon
```

You should see multiple encoder and scaler instances allocated, and a non-zero load.

### 4.4 Shared device usage
``` bash
sudo lsof /dev/nvme0n1
```

You should see multiple PIDs (one per pod’s FFmpeg process) holding the device open.

Taken together, these checks prove you have multiple pods, each doing Quadra-based encoding,
all sharing a single physical VPU.

## Cleanup
To remove the shared pool and ConfigMap:
```bash
kubectl delete -f phase2-shared-vpu-deploy.yaml
kubectl delete configmap vpu-scripts
```

Refer back to the root README.md for cluster-level teardown.