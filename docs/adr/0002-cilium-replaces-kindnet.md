# ADR-0002 — Cilium replaces kindnet as the dev CNI

Date: 2026-05-19
Status: accepted

## Context

Kind ships kindnet (a minimal bridge-CNI) by default. Production
NgolaCloud uses Cilium. Running different CNIs in dev vs prod means
NetworkPolicy semantics, observability (Hubble) and service routing
behave differently — exactly the kind of divergence we tried to
minimise.

## Decision

Disable kindnet (`disableDefaultCNI: true`) and install Cilium 1.16
via Helm at `make kind-up` time. Cilium also replaces kube-proxy
(`kubeProxyReplacement=true`, cluster created with
`kubeProxyMode: none`).

## Rationale

- **Policy parity** — NetworkPolicy + CiliumNetworkPolicy YAMLs we
  write in dev land verbatim in prod
- **Hubble** — same flow capture / service map as prod, useful for
  debugging
- **Service LB** — Cilium replaces kube-proxy, same dataplane as prod
- **Network observability** — `cilium status`, `cilium connectivity test`
  exist locally so SRE-style debugging is rehearsable

## Trade-offs

- **+~90 s boot time** — Cilium needs to deploy + agent pods need to
  init on every node
- **Tunnel mode VXLAN** — not the same as prod (which uses native
  routing on bare metal). Throughput numbers from dev are NOT a
  benchmark; functional behaviour is.
- **eBPF host routing OFF** — Kind's Docker-bridge networking trips
  some eBPF paths; `bpf.hostLegacyRouting=true` keeps everything stable
  at the cost of some CPU efficiency
- **3 GB RAM** for Cilium agents — accounted for in the 32 GB slice
  budget

## Consequences

- The default kind config in `kind/cluster-dev.yaml` MUST set
  `disableDefaultCNI: true` and `kubeProxyMode: none`. Forgetting either
  one breaks Cilium install.
- `scripts/kind-up.sh` must wait for Cilium pods Running before declaring
  the cluster ready (otherwise the test pods we deploy hit DNS failures).
