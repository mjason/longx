# Linux task resource protection

Agent commands and background jobs can run in their own cgroup v2. Longx's
supervisor stays outside the task memory domain. This is resource protection,
not a sandbox: commands still run as the person.

The installer enables `Delegate=memory` and `DelegateSubgroup=supervisor` on
systemd 254 or newer. A supported Linux service automatically creates:

```text
longx.service/                 delegated root
  supervisor/                 Longx, shim supervisors, other internal processes
  tasks/                      aggregate memory ceiling
    job-<owner>-<start>-<id>/  one command and all its descendants
```

All tasks together have a ceiling of 80% of the machine's physical memory and
1 GiB swap. A task defaults to 75% of physical memory and 1 GiB swap; global
agent settings and project overrides can lower its memory limit and change
its swap limit. Ancestor cgroup limits remain effective. A task's limit is not
reserved capacity: multiple tasks compete within the shared ceiling.

The child enters its cgroup **before executing**, using `CLONE_INTO_CGROUP`.
This includes terminal commands. Descendants inherit membership, including
those that create a new session with `setsid`. On exit, interruption or host
disconnect, the shim kills the task subtree and verifies `populated=0`.
It reads `memory.events` to distinguish an actual cgroup OOM kill from an
unrelated exit code 137.

If descendants remain alive after termination, the task reports failed cleanup
and its cgroup is retained with a quarantine marker. This also covers a root
process which does not exit after SIGKILL: the shim reports an unknown exit
status instead of waiting forever or pretending that the process died.
A later start checks quarantine markers even if the previous shim is still
alive, and detects abandoned task groups. If they cannot be emptied, it
refuses to start another workload. Parent-process exit is not treated as proof
that all GPU descendants exited.

## Availability and existing installs

Protection is optional. Agent settings select **automatic** (the default),
**off**, or **required**, with project-level inheritance/overrides. Automatic
mode attempts containment when supported; off skips it; required refuses to
start an uncontained Linux task. Memory and swap settings apply only when
containment is active.

The read-only `shim cgroup-status` command reports `eligible` or `unavailable`,
with a reason. It checks delegation prerequisites without creating groups,
changing controllers, launching a test task, or modifying systemd. Eligible
does not prove that a task is protected: seccomp, kernel support or permissions
can still prevent startup. The task's resource-guard report confirms actual
containment.

Without writable cgroup v2 delegation, automatic mode explicitly reports that
cgroup protection is unavailable and keeps the existing process-group and
whole-machine memory guards. It does not grant privileges or move the running
Longx service into another group. macOS and Windows keep their existing behavior.

Docker is not inherently unsupported, but typical containers have no writable
delegated subtree. Automatic mode can run without cgroup protection in that
case; do not grant a container broad privileges merely to enable this feature.
The container's own memory limit still applies independently of Longx's task
protection.

Updating application files alone does not change an existing systemd unit.
Re-run the Linux installer to refresh the unit, or have the administrator add:

```ini
[Service]
Delegate=memory
DelegateSubgroup=supervisor
```

Then reload systemd and restart Longx when no tasks need to be preserved.
Older systemd installations, containers and manual development launches need
an administrator-provided empty, delegated cgroup subtree. Direct shim clients
can set `cgroup: :required` and `cgroup_root: "/specific/delegated/subtree"`:
explicit requests fail closed rather than launching an uncontained task.
No arbitrary process migration or root-level hierarchy management is attempted.

The full-machine `MemAvailable` watchdog is still necessary. Task limits do
not reserve resources for unrelated services, and workloads outside `tasks/`
are not covered by its aggregate ceiling.

## NVIDIA limitation

cgroups do **not** isolate the host kernel or NVIDIA driver locks. Some GPU
driver allocations are not charged to the task memory controller. A process
stuck in a driver may also fail to exit immediately after SIGKILL. Do not
describe these limits as a guarantee that a GPU workload cannot stall the host.
GPU allocation budgets, memory headroom and failure backoff remain important.

## Verification

Unit tests cover discovery, invalid options and failed-cleanup reporting.
Real-kernel regressions run in a disposable systemd service with a 1 GiB
parent ceiling and 64 MiB task limits; they do not exhaust host memory:

```sh
systemd-run --user --wait --pipe --collect \
  --unit=longx-cgroup-regression \
  --property=Delegate=memory --property=DelegateSubgroup=supervisor \
  --property=MemoryMax=1G --property=MemorySwapMax=0 \
  --working-directory="$PWD/native/shim" --setenv=LONGX_CGROUP_TEST=1 \
  "$(command -v go)" test -count=1 -v -run TestCgroupIntegration ./...
```
