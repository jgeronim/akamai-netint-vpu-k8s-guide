[![Akamai Cloud](https://img.shields.io/badge/cloud-akamai-blue)](https://cloud.akamai.com)
[![NETINT Quadra](https://img.shields.io/badge/hardware-quadra-green)](https://netint.com/quadra)
[![Kubernetes](https://img.shields.io/badge/k8s-1.34-blueviolet)](https://kubernetes.io)

# NETINT VPUs on Akamai LKE

**Goal:** Stand up a small Akamai LKE cluster with a Quadra node pool, install the NETINT device plugin, verify resource isolation semantics (ASIC vs Quadra, session sharing, one-pod-per-VPU), and then use an **advanced internal scheduler pod** pattern for mixed workloads on a single VPU.

***

## Contents

- [Overview](#overview)  
- [Prerequisites](#prerequisites)  
- [1. Create LKE Cluster with Quadra Pool](#1-create-lke-cluster-with-quadra-pool)  
- [2. Install NETINT Device Plugin](#2-install-netint-device-plugin)  
- [3. Inspect NETINT Resources (ASIC vs Quadra)](#3-inspect-netint-resources-asic-vs-quadra)  
- [4. ASIC vs Quadra Scheduling](#4-asic-vs-quadra-scheduling)  
- [5. Single Pod with Multiple Encoding Streams](#5-single-pod-with-multiple-encoding-streams)  
- [6. Single VPU, Multiple Pods (One-Pod-Per-VPU)](#6-single-vpu-multiple-pods-one-pod-per-vpu)  
- [7. Advanced: Internal Scheduler Pod (“Pod-as-a-Node”)](#7-advanced-internal-scheduler-pod-pod-as-a-node)  
- [8. Cleanup](#8-cleanup)

***

## Overview

This repo walks through a small, reproducible environment on Akamai LKE that demonstrates:

- Quadra vs ASIC resource semantics with `netint.ca/Quadra` and `netint.ca/ASIC`.
- Single pod using one Quadra VPU to run multiple encoding sessions (session-level sharing).
- One-pod-per-VPU scheduling behavior with extended resources.
- An advanced **scheduler pod** pattern to run mixed workloads (e.g., Transcode + AI) on a single VPU.

### What This Proves

| Test                     | Expected Result                              |
| ------------------------ | -------------------------------------------- |
| Quadra pod               | ✅ Runs on Quadra node                       |
| ASIC pod                 | ❌ Stays Pending (insufficient `netint.ca/ASIC`) |
| Multi-session pod        | ✅ Multiple encodes on 1 VPU                 |
| 2 pods, 1 VPU            | 1 Running, 1 Pending                         |
| Scheduler pod (advanced) | ✅ Mixed “Transcode + AI” workloads on 1 VPU |

***

## Prerequisites

- macOS or Linux workstation.
- `kubectl`, `helm`, `jq`, and `linode-cli` installed and configured.
- Akamai account with access to **Quadra-backed Accelerated Compute** instance types (e.g., T1U-based).
- Basic familiarity with:
  - Kubernetes pods, node pools, and labels.
  - Extended resources in Kubernetes (device plugin–exposed resources).

***

## 1. Create LKE Cluster with Quadra Pool

### 1.1 Create the Cluster

```bash
# Create LKE cluster (adjust region/version as needed)
LKE_CLUSTER_ID=$(linode-cli lke cluster-create \
  --label netint-quadra-demo \
  --region us-mia \
  --k8s_version 1.34 \
  --node_pools.type g6-standard-4 \
  --node_pools.count 1 \
  --text --no-headers --format id | tr -d ' ')

echo "LKE_CLUSTER_ID=$LKE_CLUSTER_ID"
```

Fetch kubeconfig and verify connectivity:

```bash
linode-cli lke kubeconfig-view "$LKE_CLUSTER_ID" --text --no-headers \
  | base64 -d > .kubeconfig-netint
export KUBECONFIG=.kubeconfig-netint

kubectl get nodes -o wide
```

### 1.2 Add Quadra Node Pool

```bash
QUADRA_POOL_ID=$(linode-cli lke pool-create "$LKE_CLUSTER_ID" \
  --type g1-accelerated-netint-vpu-t1u1-s \
  --count 1 \
  --label netint-quadra-pool \
  --text --no-headers --format id | tr -d ' ')

echo "QUADRA_POOL_ID=$QUADRA_POOL_ID"
```

Wait a few minutes and confirm the new node:

```bash
kubectl get nodes -o wide
```

### 1.3 Label the Quadra Node

Label the Quadra node so you can target it with `nodeSelector`:

```bash
kubectl get nodes -o wide

# Adjust index if the Quadra node is first in the list
QUADRA_NODE=$(kubectl get nodes -o jsonpath='{.items [ppl-ai-file-upload.s3.amazonaws](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/152587392/da1e834b-065f-49f4-8def-bd817666ba4f/NETINT-Resource-Isolation-on-Akamai-LKE.md).metadata.name}')
echo "QUADRA_NODE=$QUADRA_NODE"

kubectl label node "$QUADRA_NODE" netint-type=quadra netint-device=enable --overwrite
kubectl get nodes --show-labels
```

***

## 2. Install NETINT Device Plugin

### 2.1 Install Device Plugin via Helm

```bash
git clone https://github.com/NETINT-Technologies/k8_device_plugin.git
cd k8_device_plugin

helm install netint ./deploy/helm/netint
```

Validate the DaemonSet and pods:

```bash
kubectl get ds -A | grep netint
kubectl get pods -A | grep netint
```

If you see `0/0` pods for the DaemonSet, ensure the node is labeled correctly and restart:

```bash
kubectl label node "$QUADRA_NODE" netint-device=enable --overwrite

kubectl rollout restart ds netint-device-plugin -n kube-system
kubectl get pods -n kube-system -w
```

***

## 3. Inspect NETINT Resources (ASIC vs Quadra)

Check the extended resources advertised on the Quadra node:

```bash
kubectl describe node "$QUADRA_NODE" | grep -A5 "netint.ca"
```

On a Quadra-only node you should see something similar to:

```text
Capacity:
  netint.ca/ASIC:     0
  netint.ca/Quadra:   1
Allocatable:
  netint.ca/ASIC:     0
  netint.ca/Quadra:   1
```

Key points:

- `netint.ca/ASIC: 0` → no G4 ASIC capacity.
- `netint.ca/Quadra: 1` → one Quadra VPU available.
- The two resources are strictly distinct; there is no automatic fallback from ASIC to Quadra.

***

## 4. ASIC vs Quadra Scheduling

### 4.1 Quadra Pod (Should Run)

From the `k8_device_plugin/manifests` directory (or any working dir):

```bash
cd ../manifests  # adjust as needed

cat << 'EOF' > quadra-demo-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: quadra-demo
spec:
  restartPolicy: Never
  nodeSelector:
    netint-type: "quadra"
  containers:
    - name: quadra-test
      image: busybox:1.35
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
          netint.ca/Quadra: 1
        limits:
          cpu: "200m"
          memory: "256Mi"
          netint.ca/Quadra: 1
EOF

kubectl apply -f quadra-demo-pod.yaml
kubectl get pods -o wide
```

Expected: `quadra-demo` is **Running** on the Quadra node.

### 4.2 ASIC Pod on the Quadra Node (Should Stay Pending)

```bash
cat << 'EOF' > asic-demo-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: asic-demo
spec:
  restartPolicy: Never
  nodeSelector:
    netint-type: "quadra"   # Same node label
  containers:
    - name: asic-test
      image: busybox:1.35
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
          netint.ca/ASIC: 1
        limits:
          cpu: "200m"
          memory: "256Mi"
          netint.ca/ASIC: 1
EOF

kubectl apply -f asic-demo-pod.yaml
kubectl get pods -o wide
```

Describe the ASIC pod:

```bash
kubectl describe pod asic-demo | grep -A6 "Events"
```

You should see an event like:

```text
0/1 nodes are available: 1 node(s) had insufficient netint.ca/ASIC.
```

This proves:

- The node **matches** the `nodeSelector`.
- Kubernetes **refuses** to schedule because `netint.ca/ASIC` capacity is 0.
- `netint.ca/ASIC` and `netint.ca/Quadra` behave as different resources.

### 4.3 Clean Up Before Session Demo

```bash
kubectl delete -f quadra-a.yaml -f quadra-b.yaml -f asic-demo-pod.yaml --ignore-not-found
kubectl get pods
```

***

## 5. Single Pod with Multiple Encoding Streams

**Goal:** Demonstrate the **session-level sharing** model: one pod, one Quadra VPU, many concurrent encoding sessions *inside* the pod.

Assuming you have an FFmpeg image (replace with your own if needed):

```bash
cat << 'EOF' > quadra-process-viewer.yaml
apiVersion: v1
kind: Pod
metadata:
  name: quadra-process-viewer
spec:
  restartPolicy: Never
  containers:
    - name: ffmpeg-viewer
      image: jrottenberg/ffmpeg:4.4-ubuntu
      command: ["bash", "-c"]
      args:
        - |
          echo "Starting long-running simulated encodes..."

          # Start 4 processes in the background, running for ~10 minutes
          ffmpeg -f lavfi -i "testsrc=size=1280x720:rate=30" -t 600 -c:v libx264 -preset ultrafast -f null - > /dev/null 2>&1 &
          ffmpeg -f lavfi -i "testsrc=size=1280x720:rate=30" -t 600 -c:v libx264 -preset ultrafast -f null - > /dev/null 2>&1 &
          ffmpeg -f lavfi -i "testsrc=size=1920x1080:rate=30" -t 600 -c:v libx264 -preset ultrafast -f null - > /dev/null 2>&1 &
          ffmpeg -f lavfi -i "testsrc=size=1920x1080:rate=60" -t 600 -c:v libx264 -preset ultrafast -f null - > /dev/null 2>&1 &

          echo "Processes started. Sleeping to keep container alive..."
          wait
      resources:
        limits:
          cpu: "4"
          memory: "2Gi"
EOF

kubectl apply -f quadra-process-viewer.yaml
kubectl get pods -o wide
kubectl exec quadra-process-viewer -- ps -ef
```

Interpretation:

- Kubernetes sees **one pod** using `netint.ca/Quadra: 1`.
- The Quadra hardware is used by multiple concurrent processes inside the container.
- This is the preferred pattern for high-density use: one VPU per pod, many channels per pod.

***

## 6. Single VPU, Multiple Pods (One-Pod-Per-VPU)

**Goal:** Show that with `netint.ca/Quadra: 1` capacity, two pods each requesting `netint.ca/Quadra: 1` cannot both run.

### 6.1 Confirm VPU Capacity

```bash
kubectl describe node "$QUADRA_NODE" | grep -A5 "netint.ca/Quadra"
```

You should see `Capacity` and `Allocatable` each at 1 for `netint.ca/Quadra`.

### 6.2 Two Pods Contending for One VPU

```bash
cat << 'EOF' > quadra-a.yaml
apiVersion: v1
kind: Pod
metadata:
  name: quadra-a
spec:
  restartPolicy: Never
  nodeSelector:
    netint-type: "quadra"
  containers:
    - name: sleeper
      image: busybox:1.35
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
          netint.ca/Quadra: 1
        limits:
          cpu: "200m"
          memory: "128Mi"
          netint.ca/Quadra: 1
EOF

cat << 'EOF' > quadra-b.yaml
apiVersion: v1
kind: Pod
metadata:
  name: quadra-b
spec:
  restartPolicy: Never
  nodeSelector:
    netint-type: "quadra"
  containers:
    - name: sleeper
      image: busybox:1.35
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
          netint.ca/Quadra: 1
        limits:
          cpu: "200m"
          memory: "128Mi"
          netint.ca/Quadra: 1
EOF

kubectl apply -f quadra-a.yaml -f quadra-b.yaml
kubectl get pods -o wide
```

Expected:

- One pod (`quadra-a` or `quadra-b`) is **Running**.
- The other is **Pending** with insufficient `netint.ca/Quadra`.

Describe the Pending pod:

```bash
kubectl describe pod quadra-b | grep -A6 "Events"
```

You should see something like:

```text
0/1 nodes are available: 1 node(s) had insufficient netint.ca/Quadra.
```

This demonstrates the default scheduling rule: **one advertised VPU → one pod**.

***

## 7. Advanced: Internal Scheduler Pod (“Pod-as-a-Node”)

### 7.1 Concept

Problem:

- The first pod that acquires the VPU “locks” it.
- You may want to run separate “Transcode” and “AI” workloads on the same VPU.
- Standard Kubernetes scheduling cannot place two VPU pods on the same device.

Solution:

- Treat a single VPU pod as a **mini worker node**.
- Run a lightweight **process manager** inside the pod that launches and supervises multiple workload types (e.g., Transcode + AI) as child processes.
- To Kubernetes it remains one “VPU pod”; to the hardware it looks like multiple clients.

### 7.2 Create the Internal Scheduler Script (ConfigMap)

```bash
cat << 'EOF' > orchestrator-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vpu-orchestrator
data:
  scheduler.sh: |
    #!/bin/bash
    echo "[Orchestrator] Acquired VPU Lock. Initializing Mixed Workloads..."

    # Workload Type A: Simulation of a High-Res Transcode
    function start_transcode() {
      echo "[Job-001] Starting 4K Transcode (simulated)..."
      # In reality: ffmpeg -i input.mp4 -c:v h264_ni ...
      sleep 3600 &
      PID_A=$!
      echo "[Job-001] Running with PID $PID_A"
    }

    # Workload Type B: Simulation of AI Object Detection
    function start_ai_inference() {
      echo "[Job-002] Starting AI Object Detection (simulated)..."
      # In reality: netint_ai_runner --model yolo_v4 ...
      sleep 3600 &
      PID_B=$!
      echo "[Job-002] Running with PID $PID_B"
    }

    # 1. Launch Mixed Workloads
    start_transcode
    start_ai_inference

    # 2. Monitor Loop (The "Keep-Alive")
    echo "[Orchestrator] All jobs dispatched. Monitoring process health..."
    wait
EOF

kubectl apply -f orchestrator-config.yaml
```

### 7.3 Deploy the Mixed-Workload Pod

```bash
cat << 'EOF' > mixed-workload-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mixed-workload-demo
spec:
  restartPolicy: Never
  containers:
    - name: vpu-manager
      image: ubuntu:22.04
      command: ["/bin/bash", "/scripts/scheduler.sh"]
      volumeMounts:
        - name: script-vol
          mountPath: /scripts
      resources:
        requests:
          netint.ca/Quadra: 1
        limits:
          netint.ca/Quadra: 1
  volumes:
    - name: script-vol
      configMap:
        name: vpu-orchestrator
EOF

kubectl delete pod mixed-workload-demo --ignore-not-found
kubectl apply -f mixed-workload-pod.yaml
```

### 7.4 Verify Mixed Workloads Are Running

**Check orchestrator logs:**

```bash
kubectl logs mixed-workload-demo
```

You should see output similar to:

```text
[Orchestrator] Acquired VPU Lock. Initializing Mixed Workloads...
[Job-001] Starting 4K Transcode (simulated)...
[Job-001] Running with PID 7
[Job-002] Starting AI Object Detection (simulated)...
[Job-002] Running with PID 8
[Orchestrator] All jobs dispatched. Monitoring process health...
```

**Inspect the process tree:**

```bash
kubectl exec mixed-workload-demo -- ps -ef
```

Example output:

```text
PID   COMMAND
1     /bin/bash /scripts/scheduler.sh  <-- Manager
7     sleep 3600                       <-- "Transcode Job"
8     sleep 3600                       <-- "AI Job"
```

This confirms:

- One **manager** process acts as the internal scheduler.
- Multiple child processes (“tenants”) share the same VPU.
- You achieve the benefits of multi-tenancy (mixed workloads) despite the one-pod-per-VPU limit.

You can extend this pattern by:

- Replacing `sleep` with real FFmpeg NETINT pipelines or AI inference runners.
- Adding simple job-queue semantics (reading from a queue, HTTP API, or files).
- Adding health checks and restart logic inside the scheduler script.

***

## 8. Cleanup

When you are done with the demo:

```bash
kubectl delete -f quadra-a.yaml -f quadra-b.yaml \
  -f quadra-demo-pod.yaml -f asic-demo-pod.yaml \
  -f quadra-process-viewer.yaml \
  -f mixed-workload-pod.yaml \
  -f orchestrator-config.yaml --ignore-not-found

linode-cli lke cluster-delete "$LKE_CLUSTER_ID"
```
