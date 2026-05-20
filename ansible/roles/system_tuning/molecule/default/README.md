# Molecule tests — `system_tuning` role

Reference implementation. Replicate this scenario for the other roles
when you're ready to expand coverage.

## Run

```bash
pip install 'molecule[docker]' molecule-plugins[docker] testinfra
cd ansible/roles/system_tuning
molecule test         # full lifecycle
molecule converge     # iterate locally — keeps the container alive
molecule verify       # re-run testinfra against the converged container
molecule destroy
```

## What's tested

- sysctl override file written + values applied at runtime
- `/etc/modules-load.d/ngolacloud-dev.conf` present
- udev I/O scheduler rule present (rule effect requires real hardware)
- GRUB cmdline contains `transparent_hugepage=madvise` + `cgroup_enable=memory`
- swap file exists with mkswap header + correct perms
- `/etc/fstab` persists the swap entry
- THP runtime is `madvise` (when /sys/kernel is writable in the container)

## What's NOT tested

- GRUB update-grub effect (container has no boot loader)
- Real udev rule application (container has no real block devices)
- swap actually `swapon`-ed (container security profile blocks)
- Reboot behaviour

Real-hardware coverage of those gaps belongs in the **smoke test
workflow** (`.github/workflows/smoke.yml`) which runs on a GitHub
Actions Ubuntu runner with a real kernel.

## Add a new role's tests

```bash
cd ansible/roles/<role-name>
mkdir -p molecule/default/tests
# copy molecule.yml, converge.yml, tests/test_default.py from here
# edit the role name in converge.yml + the assertions in test_default.py
```
