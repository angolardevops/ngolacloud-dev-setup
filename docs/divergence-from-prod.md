# Divergence from production — what `make kind-up` does NOT validate

The local Kind lab is **deliberately not** a faithful copy of production.
~80% of behaviour transfers; ~20% only shows up on real hardware. Be
explicit about which side of the line your change sits on, and gate the
risky 20% behind a real-hardware test (Z440 staging, Hetzner, T5600)
before promoting.

## Side-by-side

| Aspect | DEV (this workstation) | PROD (Z440 / Hetzner / T5600) |
|---|---|---|
| OS | Zorin 18 (Ubuntu 24.04 LTS base, kernel 6.17) | Ubuntu Server 24.04 LTS, kernel 6.x |
| Cluster bootstrap | `kind` — Kubernetes nodes are Docker containers on the host | `kubeadm` on real (or KVM) VMs |
| Virtualisation | none — pods talk to the host kernel directly | KVM + libvirt + virtio devices |
| CNI | Cilium in Kind-compatible mode (VXLAN tunnel, host-legacy routing) | Cilium in full eBPF mode |
| Service LB | Cilium (`kubeProxyReplacement=true`) | Cilium + MetalLB IPAM |
| Storage | Docker volumes on `/var/lib/docker` (ext4) | ZFS or Ceph RBD |
| Networking | Single Docker bridge, MTU 1500 | Linux bridges + VLANs, 10 GbE NIC, MTU 9000 |
| HA | None (single CP node) | 3 stacked control planes + kube-vip VIP |
| Storage class | `standard` (Docker volume) | `longhorn-ssd` / `ceph-rbd` |
| Ingress | `ingress-nginx` on host ports 80/443 | `ingress-nginx` behind MetalLB LB |

## What works the same in both

- Pod scheduling, RBAC, NetworkPolicy semantics, Service DNS
- ConfigMap / Secret mounts
- Helm charts (`ngolacloud-portal`, `cert-manager`, `external-secrets`)
- Most Cilium L3/L4 policies and Hubble flow capture
- `kubectl exec`, `kubectl logs`, `kubectl port-forward`
- Container image builds (`docker build` produces identical layers)
- Anything that talks only to the Kubernetes API

## What does NOT translate

| Area | Why it diverges | What to do |
|---|---|---|
| **PV/PVC binding** | Docker volumes aren't ZFS — no snapshots, no replication | Test with the staging Longhorn cluster before relying on snapshot/restore |
| **NUMA pinning** | Kind nodes share the host's NUMA layout — no separation | Don't tune via `nodeAffinity` or CPU manager policies locally |
| **HugePages** | THP=madvise on the host; pods don't see explicit hugepages | Hugepages-requiring pods (some DBs) will run but with degraded perf |
| **Network policies that target node IPs** | Kind worker IPs are Docker IPs (172.x.x), not LAN | Express policies via pod labels or CIDR-of-pod, never node IPs |
| **eBPF host routing** | Disabled (`bpf.hostLegacyRouting=true`) — Docker-bridge incompatibility | Network throughput numbers from Kind are NOT a prod benchmark |
| **Multi-AZ failover** | Single node, single zone topology | Use the 3-CP staging cluster |
| **Storage performance** | NVMe direct beats virtio-blk; results are 2-3× optimistic | Re-bench on prod metal |
| **VLAN segmentation** | One flat Docker network | Test VLAN-tagged ingress only against staging |
| **kube-vip / VIP behaviour** | No VIP (single CP) | Failover testing only on 3-CP clusters |
| **MetalLB IP pools** | ingress-nginx hostPorts replace LB | Cannot test BGP advertisements locally |

## Validation tiers

```
   Dev (Kind)  ──► Stage (3-VM kubeadm cluster on this laptop, nested KVM)
                                       │
                                       ▼
                                  Pre-prod (Z440)
                                       │
                                       ▼
                                       Prod (T5600 / Hetzner)
```

A change is "ready for prod" when it has passed:

1. **Kind**: behaves correctly in `make kind-up && kubectl apply -f …`
2. **Nested staging**: same playbook on the laptop's 3-VM KVM stack
   (16 GB budget — `ngolacloud infra dev --variant=nested`)
3. **Z440 staging**: real hardware, real network, but no customer data
4. **Prod**: customer-facing
