# Troubleshooting — top 10 lab failures

Compact runbook for the failures that show up most often when running
`make setup` + `make kind-up` on a fresh workstation. Each entry: how
to spot it, the root cause, the fix.

## 1. `make setup` fails with "cgroup v2 unified hierarchy required"

**Spot:** Preflight task aborts after listing the OS version.

**Cause:** `/sys/fs/cgroup/cgroup.controllers` doesn't exist — the
kernel booted with the legacy hybrid hierarchy.

**Fix:** edit `/etc/default/grub`, ensure `GRUB_CMDLINE_LINUX_DEFAULT`
contains `systemd.unified_cgroup_hierarchy=1`, run `sudo update-grub`,
reboot.

## 2. Docker says "Cgroup Driver: cgroupfs" after `make setup`

**Spot:** `docker info | grep Cgroup` returns `cgroupfs`.

**Cause:** Snap Docker silently survived the install. The role aborts
on detection but if the symlink moved you may have a lingering snap.

**Fix:** `sudo snap remove --purge docker`, then re-run `make setup`.

## 3. `kind create cluster` hangs at "Preparing nodes"

**Spot:** No progress for >2 min; `docker ps` shows the node container
but it's in `Created`, not `Up`.

**Cause:** Almost always one of:
- Out of memory — the slice's `MemoryHigh` is throwing pressure
- Out of disk — `/var/lib/docker` filesystem full
- A stale Kind network — Docker can't allocate the subnet

**Fix:**
```bash
make kind-down
docker network ls | grep kind
docker network rm kind 2>/dev/null || true
free -g                # check available memory
df -h /var/lib/docker  # check disk
make kind-up --recreate
```

## 4. Cilium pods CrashLoopBackOff after install

**Spot:** `kubectl -n kube-system get pods -l k8s-app=cilium` shows
restarts > 0.

**Cause:** Two common ones:
- `cilium-config` ConfigMap is missing values for routing mode
- The k8s API server isn't reachable from the kind network (DNS issue
  inside the container)

**Fix:**
```bash
kubectl -n kube-system logs ds/cilium --tail=80
# If you see "could not resolve API server", check /etc/hosts in the
# kind-control-plane container:
docker exec ngolacloud-dev-control-plane cat /etc/hosts
# Re-install with explicit k8sServiceHost:
helm upgrade cilium cilium/cilium -n kube-system \
  --reuse-values \
  --set k8sServiceHost="ngolacloud-dev-control-plane"
```

## 5. Pods stuck in Pending with "no nodes available"

**Spot:** New pods sit in Pending; `kubectl describe` mentions
"0/4 nodes are available".

**Cause:** Workers are NotReady — usually a Cilium init container
hasn't finished, or the node is cordoned.

**Fix:**
```bash
kubectl get nodes -o wide
kubectl describe node <name> | grep -E "Conditions|Taints"
# If MemoryPressure: yes — the slice is too tight; raise MemoryMax in
# inventory.ini and re-run `make setup TAGS=slice`.
```

## 6. Disk fills up at 95%+ silently

**Spot:** `make health` shows Disk in red; pods start failing with
`ImageInspectError`.

**Cause:** Docker layers + buildkit cache + dangling images
accumulate over Rust rebuilds and Kind recreates.

**Fix:**
```bash
make prune                # safe — keeps volumes
make prune-aggressive     # also drops unattached volumes
# Nuclear: bring everything down first
make kind-down-deep
docker system prune -af --volumes
```

## 7. `make setup` says "GRUB changed" but reboot doesn't help

**Spot:** After reboot, `cat /sys/kernel/mm/transparent_hugepage/enabled`
still shows `[always]` instead of `[madvise]`.

**Cause:** `update-grub` didn't run, or the wrong grub config got
updated (UEFI vs BIOS).

**Fix:**
```bash
grep transparent_hugepage /etc/default/grub          # must contain madvise
sudo update-grub                                       # regenerate
grep -E '^(linux|module2)' /boot/grub/grub.cfg | head # confirm madvise in actual boot config
sudo reboot
```

## 8. Permission denied on `docker ps` after `make setup`

**Spot:** Plain user can't run docker without sudo.

**Cause:** The `docker_engine` role added the user to the docker group,
but the change only takes effect in new login sessions.

**Fix:** `newgrp docker` (current shell), then log out / log back in
to make it permanent.

## 9. `kind load docker-image` returns "image not found"

**Spot:** Script says `Image X is not present locally` even though
`docker image inspect X` works.

**Cause:** You're using the wrong kind cluster name. The script defaults
to `$KIND_CLUSTER=ngolacloud-dev`; if you have other clusters you may
need to pass it explicitly.

**Fix:**
```bash
KIND_CLUSTER=other-cluster scripts/kind-load-image.sh ngolacloud/portal:0.1.0
```

## 10. `make setup` randomly fails halfway through, second run works

**Spot:** Apt download fails / GPG error / sha256 mismatch on first
run; second run is clean.

**Cause:** Almost always slow / dropping Wi-Fi during the download
phase. Less commonly: GitHub rate-limit (anon downloads).

**Fix:**
- Wired connection is more reliable than Wi-Fi for big downloads
- Set `GH_TOKEN=$(gh auth token)` in env before `make setup` to
  authenticate Ansible's GitHub release downloads (raises rate limit)
