# ADR-0001 — Kind chosen over minikube and k3d

Date: 2026-05-19
Status: accepted

## Context

The workstation needs a local Kubernetes runtime for `ngolacloud infra
dev`. Three candidates: kind, minikube (docker driver), k3d.

## Decision

Use **kind v0.30+** with Kubernetes 1.32+.

## Rationale

| Criterion | kind | minikube/docker | k3d |
|---|---|---|---|
| Same K8s as prod (kubeadm) | ✓ | ✓ | ✗ (k3s) |
| CNI swappable to Cilium | ✓ | partial | ✓ |
| Multi-node default | ✓ | ✗ (single node default) | ✓ |
| Boot time | ~90 s | ~120 s | ~60 s |
| Image load API | `kind load docker-image` | `minikube image load` | `k3d image import` |
| Used by upstream K8s SIG | ✓ (sig-testing) | partial | ✗ |
| Image registry sub-system | none (use external) | embedded | embedded |
| Production parity | high | medium | low (k3s != kubeadm) |

The deciding factors:
- We want **kubeadm semantics** in dev so failures we see locally
  mirror what kubeadm does on Z440 — k3d's k3s is a different
  control plane (sqlite by default, different addons).
- Cilium documented support for Kind is first-class.
- `kind load docker-image` is fast and contract-stable; we use it on
  every code → portal iteration.

## Consequences

- We pay ~30 s longer boot than k3d.
- No embedded registry — push to a local registry or use
  `kind load docker-image` per build.
- Multi-node default uses ~4 GB more RAM than k3d, but it matches prod
  topology so failures map.
