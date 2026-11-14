# Sandboxed Buildkite agent

This repository hosts Julia's sandboxed Buildkite workers.


## Architecture

Each host runs one scheduler, configured with runner groups. A group is one
sandbox backend with its worker tags, serving one or more Buildkite queues from
one pool of slots (worker identities, each with its own caches, made as jobs need
them); it registers a Buildkite Stack per queue. The scheduler polls
for jobs, admits them against the host's CPU and memory budgets, reserves each
one, chooses its cache, and launches an agent with `--acquire-job` inside the
configured sandbox.

The agent registers with a job acquisition token, minted for that one job right
before the agent starts and valid until the job's reservation ends (at most an
hour). The cluster agent token in `secrets_dir` is used only by the scheduler,
for the Stacks API; it never enters a sandbox or guest. A job Buildkite does not
issue a token for is never started. When minting keeps failing (rate limits,
5xx and network errors are retried until the reservation ends), the job is not
started and not held against it: its reservation expires and Buildkite offers
it again.

### Job selection

Jobs are selected only when their Buildkite agent query rules match the worker's
tags. This follows Buildkite's positive `key=value` and `key=*` matching
semantics; the Stack handles the queue match, and every `sched_*` rule is a
request to the scheduler (see below) rather than a rule for the agent.

### Job sizes

The scheduler fits jobs onto hosts and tells each job what it got:

1. **Hosts state facts.** Each host's configuration says how many CPUs
   (`total_cpus`) and how much memory (`total_mem_gib`) it has for jobs. On
   Apple Silicon `total_cpus` counts the performance cores only, and
   `total_mem_gib` is physical memory minus what the OS and the scheduler need.
   No host configuration names how wide a particular job runs.
2. **A job's size is its `sched_*` tags, else its runner group's default for
   the job's queue.** Sizes are capped at the group's limits (on KVM,
   `max_cpus` and `max_mem_gib`) and CPUs at `total_cpus`. The scheduler
   admits the job once that size fits what is left of the host; it never
   shrinks a size to fit what is currently free, the job waits instead. A size
   the host can never hold (more memory than `total_mem_gib`) is skipped as
   impossible and left to other hosts.
3. **An untagged macOS job gets the whole host:** `total_cpus` CPUs and
   `total_mem_gib` GiB, so it runs alone. Only steps that declare a size with
   `sched_*` tags share a Mac, with each other.
4. **The granted size is exported to the job** as `SBA_CPUS`,
   `SBA_CPUS_LIMIT`, `SBA_MEM_GIB` and `SBA_MEM_LIMIT_GIB` (see
   [Job environment](#job-environment)), by every backend. Jobs size themselves
   from these rather than probing `nproc`, `hw.memsize` or cgroups.

Pipeline steps size their jobs with agent tags next to `queue`. Like
Kubernetes' requests and limits, each resource has a request, what the job
typically uses, and an optional limit, the most it may use, which defaults to
the request and may not be below it:

```yaml
agents:
  queue: "build"
  sched_cpus: "4"            # request: charged against the host's `total_cpus`
  sched_cpus_limit: "16"     # CPUs it may run on: Linux cpuset, KVM vCPUs; SBA_CPUS_LIMIT
  sched_mem_gib: "12"        # request: charged against the host's `total_mem_gib`
  sched_mem_limit_gib: "40"  # Linux memory.max; KVM guest RAM
```

`sched_cpus` is what the job is charged: admission keeps the sum of requests
within `total_cpus`, and a Linux job's `cpu.weight` is `100 × cpus`. A weight is
a share relative to its siblings in one cgroup, not a number of cores: under
contention, jobs split the CPU time in proportion to their requests, next to the
scheduler's own supervisor cgroup and uncharged jobs (which weigh as one CPU),
while idle cores stay available to anyone. `sched_cpus_limit` is how wide the job
runs; only bursty jobs, such as builds that alternate parallel phases with long
serial ones, set it above `sched_cpus`. The CPU limit is a width, not a time
quota: it is enforced through the job cgroup's `cpuset.cpus` (vCPUs on KVM),
and there is no `cpu.max`.

`sched_mem_gib` is what the job typically uses, and what it is charged:
admission keeps the sum of the memory requests of Linux and macOS jobs, and of
the reservations of KVM guests (below), within `total_mem_gib`. A job asking
for more than `total_mem_gib` never runs on the host and is left to others; a
group `default` asking for more is a configuration error. A request of 0 (a
Linux group `default` without `mem_gib`) charges nothing. Limits may add up to
more than the budget, since jobs rarely peak at once; on Linux,
`min_mem_available_gib` is the backstop for when they do.

A step without any of these tags gets its runner group's `default` size for
the job's queue (see [Runner groups](#runner-groups)), so hosts can run untagged
pipelines at today's sizes, and queues such as pipeline uploads need no tags at
all. A step that sets any `sched_*` tag makes a complete request: `sched_cpus`
and `sched_mem_gib` are then required, all values must be positive integers set
with `=`, and a limit may not be below its request. The scheduler owns the whole
`sched_*` namespace: any other `sched_*` key, such as a typo, is an error
rather than a tag some agent might advertise.
The scheduler fails a job whose request is incomplete or invalid, or that has no
tags and no `default` to fall back on, with a message saying so, rather than
guessing its size or leaving it to wait for an agent that never comes.

CPU requests and limits are capped at `total_cpus`; on KVM, vCPUs and guest RAM
are capped at the group's `max_cpus` and `max_mem_gib`. A request is then capped
at its limit: a 6-vCPU guest asked for 8 CPUs is charged 6.

On macOS, a step without tags gets the whole host, and a step with tags gets
its request, as on Linux. Nothing enforces the size there: a Mac has no cgroups
or cpusets, and the seatbelt does not isolate concurrent jobs from each other's
load. A tagged job is trusted to stay within its `SBA_CPUS_LIMIT` (the
environment hook sets `JULIA_CPU_THREADS` from it) and its memory request. Tag
only light, short steps on macOS, and never a test suite or a step that times
itself (benchmarks), so that what needs the whole Mac still gets it. A whole-host
job waits until the tagged jobs on the host have finished; newer tagged jobs
keep starting meanwhile only for a bounded time (see [Admission](#admission)).

On Linux, `sched_mem_limit_gib` is the job's `memory.max`. A job over its limit
is OOM-killed: the kernel kills the job's largest process, the agent reports the
failure, and OOM kills are also logged before the job's cgroup is removed. Swap
is disabled for the job (`memory.swap.max = 0`) only where the kernel has swap
accounting; on kernels booted without it (5.4 on the POWER9 hosts) a job can
swap past its limit before it is killed. On KVM, the guest gets `sched_mem_limit_gib`
of RAM and reserves it plus the host overhead (2 GiB) against
`total_mem_gib`.

CPUs are a budget rather than specific cores: a Linux job's cgroup gets
`cpu.weight = 100 × cpus`, so CPU time is shared in proportion to requests under
contention and idle cores stay usable, and KVM domains get the same weight
through their CPU shares. libvirt places domains in its own `machine.slice`,
though, not next to the scheduler's job cgroups, so a guest's weight only
competes with other guests: Linux jobs and KVM domains on one host are not
weighed against each other.

Each Linux job also runs on a cgroup cpuset of `cpus_limit` CPUs, those least
used by the other running jobs among the CPUs the scheduler's own cgroup may use
(`cpuset.cpus.effective`, which need not start at 0 or be contiguous). Use is
counted per core first: a job gets one CPU on each idle core before any SMT
sibling of a busy one, since two threads sharing a core each run 30-50% slower
than on cores of their own. The siblings come from
`/sys/devices/system/cpu/cpu*/topology/thread_siblings_list`. Julia's
`--threads auto`, libuv's available parallelism and `nproc` follow the CPU
affinity, which the cpuset bounds, rather than any environment variable, so an
unconstrained job would start a thread per host CPU, which a 32-bit process
cannot even hold. The kernel enforces the cpuset for every process of the job:
a job cannot widen it, and pinning a thread outside it (`JULIA_EXCLUSIVE=1`)
fails rather than escaping. The cpuset bounds how wide a job runs; `cpu.weight`
still decides its share, and cpusets may overlap when the host is
oversubscribed. The scheduler's systemd unit delegates the `cpu`, `cpuset` and
`memory` controllers (`Delegate=cpu cpuset memory`, written by `sba enable` or
`sba reinstall`), and the scheduler does not start without them.

Jobs cannot change these limits or leave their cgroup: Sandbox.jl gives each
sandbox a cgroup namespace rooted at its job cgroup and a read-only view of it
on `/sys/fs/cgroup`, and locks the sandbox's mounts so the view cannot be
removed. That only holds when the host mounts cgroup2 with `nsdelegate`
(systemd's default), which the scheduler checks at start.

Never add a `cpu.max` quota to the scheduler's or a job's cgroup. Once the
job's cgroup has a quota, Julia's bundled libuv (Julia 1.12 and later) reports
its available parallelism as (quota / period) × (`cpu.weight` / 100), at least
1 and at most the CPUs of its affinity mask; without a quota it ignores the
weight. The scheduler sets `cpu.weight` from the CPU request (100 × `cpus`), so
a quota would make what Julia sees depend on the request and the quota rather
than on the cpuset.

### Job environment

Every backend (Linux sandbox, macOS seatbelt and the KVM guests) exports the
job's granted allocation:

| Variable | Value |
|---|---|
| `SBA_CPUS` | CPU request charged to the job (`0` for an uncharged job) |
| `SBA_CPUS_LIMIT` | CPUs the job may run on: its cpuset on Linux (every CPU of the scheduler's cgroup for groups without a CPU limit), on macOS the CPU limit of a tagged job and the whole host's `total_cpus` otherwise (advisory), the vCPUs on KVM |
| `SBA_MEM_GIB` | Memory request in GiB; unset when the job was granted none |
| `SBA_MEM_LIMIT_GIB` | Memory limit in GiB: Linux `memory.max`, KVM guest RAM, advisory on macOS; unset when unlimited |
| `SBA_ADMISSION` | One line on how the job was admitted, for people: its size and where that came from (tags, the queue's default, the whole host), the size before caps if it was capped, the memory charged where that differs from the request (KVM), what of `total_cpus` and `total_mem_gib` was free, and how long after Buildkite made it runnable |

`BUILDKITE_AGENT_META_DATA_SCHED_*` (from the agent tags) carries what the step
*requested*; `SBA_*` is what the job was *granted*, after defaults and caps.

`XDG_CACHE_HOME` is the job's cache pool: `/cache` on Linux and in FreeBSD
guests, `C:\cache` in Windows guests, and the pool's own path on macOS (see
[Cache isolation](#cache-isolation)). Until julia-buildkite-plugin v1 is gone,
`BUILDKITE_PLUGIN_JULIA_CACHE_DIR` is exported too, with the directory v1 has
always used; v2 prefers it over `XDG_CACHE_HOME`, so neither version moves its
cache while it is set. The KVM images set both too, from their next rebuild.

The shipped environment hook,
[`agent/hooks/environment.d/101_julia_num_cores.sh`](agent/hooks/environment.d/101_julia_num_cores.sh),
sets `JULIA_CPU_THREADS` to `SBA_CPUS_LIMIT`, so existing pipelines keep
working; a `JULIA_CPU_THREADS` set by the step itself wins. A job with neither
is failed with a message: the hook never guesses a width from `nproc`. On
Linux it also sets `OMP_THREAD_LIMIT` to the same value unless the step set
it, so coreutils `nproc` agrees; on macOS, which has no `nproc`, it defines an
`nproc` function that prints `JULIA_CPU_THREADS`. On Linux the cpuset is what
enforces the width: Julia's `--threads auto`, `Sys.EFFECTIVE_CPU_THREADS`,
libuv and `nproc` follow it without any variable.

Another, [`agent/hooks/environment.d/190_admission.sh`](agent/hooks/environment.d/190_admission.sh),
prints `SBA_ADMISSION` in an `Admission` section near the top of the job log,
and nothing when it is unset. The same facts, as fields, are in the job's
resource record (meta-data `sba/<job id>`, see `allocation_record` in
`src/resources.jl`), next to what the job used.

The KVM guest images carry their own copy of this hook and, on Windows, of the
launcher that passes `SBA_*` on to the agent service; a rebuilt image's hook
fails jobs without `SBA_CPUS_LIMIT`. Roll a new scheduler out first and rebuild
the images afterwards.

### Admission

Each poll lists a queue's scheduled jobs, oldest first, up to the oldest 2000;
a failed poll leaves its queue with no pending jobs until the next one succeeds.
A job is pending here while it matches a group's tags, is not claimed or
quarantined (see below), and has been runnable for its group's `min_job_age`.
Admission takes the pending jobs of all groups and queues in one order:

1. runner-group `priority` (lower first);
2. Buildkite job `priority` (higher first);
3. age: the build's `scheduled_at`, then the job id. A job that waited on
   earlier steps keeps its build's place, so old builds finish first.
   `min_job_age` instead counts from the job's own `runnable_at`.

Jobs start in that order while their request fits what running jobs leave of
`total_cpus` and of `total_mem_gib` (the memory request; for KVM, guest RAM plus
host overhead). A request of zero CPUs and zero memory (launchers: `cpus = 0`
and no `mem_gib`) always fits once the pass reaches it. Jobs that fit may start
ahead of one that does not until that job has been runnable on Buildkite
(`runnable_at`) for 10 minutes. From then on, or at once if its `runnable_at` is
unknown, it stops the pass: nothing after it starts, in any group, until it
does. A big or high-priority job is thus overtaken for at most 10 minutes,
while a busy host keeps starting small jobs instead of idling until it is empty. A job that already waited for
other hosts or for `min_job_age` has less of the 10 minutes left. Running jobs
are never preempted.

The order is over the jobs this host could start now, so some jobs neither start
nor hold others back:

- jobs of a group running `max_slots` jobs (only groups that set it). Only that
  group's own jobs free a slot, and holding back other groups until then would
  leave the host idle. The
  cost is accepted: when the slot frees, the group's next job may find the CPUs
  taken by lower-priority jobs and wait for them, from then on blocking like any
  head;
- jobs whose memory charge exceeds `total_mem_gib`: they can never run here, and
  are skipped with a warning.

On Linux, while `MemAvailable` is below `min_mem_available_gib`, nothing is
admitted at all.

Free disk space is not an admission input: how much a job will write cannot be
known in advance, so a job is admitted however full its filesystems are. Cache
retention frees space alongside admission (see [Cache retention](#cache-retention)).

A job's slot and resources are released only once its teardown is confirmed:
every process of its Linux cgroup killed (one by one where the kernel has no
`cgroup.kill`) and the cgroup removed, or its KVM domain gone. A slot whose job
survives stays leased and charged, shows as `quarantined` in `sba status` and
`sba_slots_quarantined`, and is released when a retried teardown succeeds; a
stop also stops, waits for and reports such jobs. A scheduler does not start
while job cgroups or domains of an earlier one survive.

A job this host reserved but could not run (a failed setup, a guest that did not
boot) is not failed in Buildkite the first time, since finishing it would fail
the build for good and the cause is usually the host. The scheduler skips the
job until its reservation has expired, so another host (or this one, later) can
take it; it shows under "Quarantined jobs" in `sba status`. If the same job fails
on this host again within six hours of its previous failure (during the same
scheduler run), it is finished with exit status -1 and a detail
naming the host and the error. If finishing fails, the job is skipped until its
reservation expires again, and its next failure here tries again. The same
skip applies when a reserved job's environment cannot be fetched, its cache pool
is unavailable, or a job that cannot be sized cannot be failed.

### Cache isolation

After reserving a job, the scheduler fetches its environment and selects a cache.
The main cache is partitioned by worker, pipeline UUID, and trust level:

```
<cachedir>/<runner-group>-<host>.<worker>/<pipeline-uuid>/<protected|untrusted>/
```

A job uses the protected cache only if all of these hold for its build:

- it is not a pull request (`BUILDKITE_PULL_REQUEST=false`);
- it was created by a GitHub webhook, a pipeline schedule, or a person in the
  Buildkite web UI (`BUILDKITE_SOURCE` is `webhook`, `schedule` or `ui`);
- it is of a protected ref: the branch `master` or `main`, a branch starting with
  `release-`, or a tag build of a version tag (`v` and a digit, such as `v1.12.0`).

Everything else uses the untrusted cache: pull requests (also same-repo ones from a
`release-*` branch), pushes to other branches, and builds created through the REST
API or by a trigger step. Source and branch are also what a Buildkite secrets access
policy can check (`build_source`, `build_branch`), but such a policy cannot tell pull
requests or tag builds apart: it admits same-repo pull requests from a protected
branch, which use the untrusted cache here.

If the job's environment cannot be fetched, the job is not run: it stays reserved
until the reservation expires, and Buildkite then offers it to every host again.

Untrusted jobs cannot write caches read by protected jobs, pipelines do not share
caches, and each worker has exclusive access to its cache. Pull requests within
one partition reuse the untrusted cache; caches are not created per PR or primed
from protected builds.

Linux may additionally configure a shared compiler cache. It omits the worker
dimension but retains the pipeline and trust boundaries:

```
<sharedcache>/<pipeline-uuid>/<protected|untrusted>/
```

macOS and KVM do not support this shared cache. KVM persists a cache-disk overlay
in the main partition and recreates the OS-disk overlay for each job.

#### The cache contract

Plugins and pipelines find their cache through a convention any runner can
provide, not through anything specific to this scheduler:

- The runner gives each job one writable directory in `XDG_CACHE_HOME`; here,
  the job's pool. A plugin keeps its files in `${XDG_CACHE_HOME}/<plugin-name>/`,
  defaulting to `$HOME/.cache/<plugin-name>/` where the variable is unset, so a
  laptop or a plain agent works unchanged. Tools that follow XDG (ccache 4, pip)
  land in the pool as well.
- Plugins never prune, measure or age out their cache: eviction and trust are the
  runner's job. They must tolerate the directory being emptied at any time
  between jobs, and use atomic renames for what they install.
- One job at a time per `XDG_CACHE_HOME`: plugins may reset per-job state in it
  (julia-buildkite-plugin resets its depot's per-job parts). Here each pool
  belongs to one slot, which runs one job at a time; `XDG_CACHE_HOME` never
  points at a shared pool (`/sharedcache`), whose concurrent users are
  pipelines that manage it themselves (ccache).
- Read-only stores, where a runner has them, are found through lookups that exist
  anyway (`JULIA_DEPOT_PATH` after the plugin's own depot, the agent's git mirror
  configuration), never through new variables.

### Cache retention

The scheduler deletes pools; nothing else needs to. It never measures what is in
a pool (no `du`): it looks only at each filesystem's free space (`statvfs`), as
`df` reports it.

- **Stamps.** Each pool has a stamp next to it, `<trust>.sba-pool`, outside what
  the job can write, recording when the pool was created and last used. The
  scheduler writes it when a job takes the pool and when the job's slot is
  released. A pool without a stamp (from before stamps) counts as last used when
  its newest top-level entry changed.
- **Leases.** A pool is held from the job's assignment until its teardown is
  confirmed (also while a slot is quarantined), and no held pool is deleted. A
  deletion renames the pool into `<root>/.sba-trash/` under the same lock that
  hands pools out, so a job never gets a pool that is being deleted; an `rm -rf`
  process then removes it, off the scheduling loop. `rm` deletes symbolic links
  instead of following them and does not cross into other filesystems, so a link
  a job planted never takes anything outside the root with it. Trash a crash
  leaves behind is removed at the next start.
- **Eviction.** Above a filesystem's high-water mark, idle pools on it are
  deleted whole, one at a time, measuring free space again after each (ZFS and
  open files free space late), until the low-water mark is reached, at most ten
  per pass. On ZFS, which shows freed space only when it writes out the
  transaction group holding the frees (normally triggered every
  `zfs_txg_timeout`, 5 seconds), free space is measured after a deletion until
  it has not grown for that interval plus a second, for at most four such
  intervals: a best effort, which a slow sync or jobs writing meanwhile can
  defeat.
  First go pools nothing will use again: those of slots no longer configured, and
  of pipelines none of whose pools on the host was used for `cache_retired_days`. Then the least recently used. Low slot
  indices are used first, so the pools of high slots are the first to cool down.
- **Maximum age.** A pool older than `cache_max_age_days` is reset (deleted, and
  the next job starts empty), between 75% and 100% of that age depending on a hash
  of its path, so caches do not all go cold together. This bounds the pools that
  are always in use and so never idle long enough to be evicted; expect a cold job
  (downloads, recompilation) after each reset. A pool that expires while held is
  reset when it is released, before its slot can take it again. Idle pools are
  checked every ten minutes and whenever a filesystem needs eviction.
- **Shared pools** (`sharedcache`) are used by many slots at once, so they are
  counted per job and never evicted or reset while held, or while their pipeline
  is live. When the first job takes one, the scheduler sets `max_size` in
  `<pool>/ccache/ccache.conf` (`ccache_max_size_gb`; pipelines point `CCACHE_DIR`
  at `/sharedcache/ccache`), keeping any other settings. Shared pools of retired
  pipelines are evicted, and idle ones unused for `cache_max_age_days` reset.
- **KVM cache disks** are part of their pool and discarded with it, never mounted
  or trimmed. A pool holding a disk that a running domain uses is not touched,
  whatever its lease says; if libvirt cannot list the domains' disks, nothing is
  deleted. Pristine images and the backing chains in `platforms/` are never in a
  cache root.
- **Leftovers.** The scratch, temporary and persistence directories of slots no
  longer configured (of renamed or removed groups, or above a lowered
  `max_slots`) are removed:
  only `<tempdir>/agent-tempdirs/<slot>`, `<tempdir>/kvm-agent-scratch/<slot>`
  and `persist-<slot>` in a `persistence_dir` or `cachedir`, and only for names
  of this host's slots.

Retention never gates admission: a job starts however little space is left, and
retention only deletes idle pools. This is best-effort disk management. Nothing
bounds what a running job writes: a job that fills the disk faster than the
scheduler reacts (every `disk_check_interval`), or a disk with no idle pool left
to evict, still fails jobs with `ENOSPC`, as it would without it. The scheduler
does not export free space; watch and alert on node_exporter's
`node_filesystem_avail_bytes` instead. A cache root must belong to one scheduler:
the scheduler deletes whatever pools and slot directories of this host's naming
it finds there.

On ZFS, keep the roots in a pool (`cachedir`, `sharedcache`, `tempdir`,
`persistence_dir`) in one dataset, without snapshots. `statvfs` on a dataset counts only that dataset's data as used,
against the space available to the dataset (the pool's free space, less quotas
and reservations), so the thresholds compare the scheduler's data with the
space left for it. Roots in several datasets of one pool would each
look emptier than the pool is, and evicting the pools of one would free space
that another one's threshold is waiting for; the scheduler warns about such a
pool. Evicting data a snapshot still holds frees nothing, yet it stops counting
as used.


## Command-line interface

The main entry point is `bin/sba`:

```
❯ ./bin/sba --help
usage: sba [--config PATH] <command> [options]

Commands:
  scheduler     run the scheduler in the foreground
  enable        generate and enable the host scheduler service (does not start it)
  start         start the enabled scheduler service
  stop          stop the running scheduler service and clean up backend resources
  restart       restart the enabled scheduler service and report interrupted jobs
  reinstall     regenerate and restart the scheduler service and report interrupted jobs
  status        show scheduler service state and the latest scheduler snapshot
  logs          show scheduler or per-slot backend logs
  disable       stop the scheduler and remove its service and host setup

Global options:
  --config PATH   path to the config file (default: ./config.toml)
  -h, --help      show this help message
```

`stop`, `restart`, `reinstall` and `disable` first ask the scheduler to stop by
writing `stop-request` into its `logdir`; on Linux, a plain `systemctl stop` does
the same through the unit's `ExecStop`. The scheduler then admits nothing more
and stops the running jobs one at a time, a few seconds apart: it stops each
job's agent and, two seconds later, kills the job's processes rather than wait
out the agent's cancel grace period. The agent then reports the job as
`exit_status -1` with `signal_reason: agent_stop` and exits, and the scheduler
deregisters its stacks. KVM guests get the same treatment from inside the
guest: the agent is stopped, then the job's processes are killed (on Windows,
through console interrupts, and the job's bootstrap is ended with the exit code
the agent reports as -1). Buildkite records these jobs as `agent_stop` too. A
Windows guest whose agent has not exited within ten seconds is shut down
cleanly, as are guests after their job.
Jobs still running after the grace period are force-stopped. If the scheduler has not exited after ten
minutes, the service is killed as before.

Nothing retries the interrupted jobs: pipelines carry no retry rules for them.
Once its kill phase is over, the scheduler writes the jobs it interrupted, and
those that survived the stop, to `stop-report.json` in its `logdir`; jobs that
ended by themselves meanwhile are left out. The commands print one
`bk job retry JOB_ID` line for each, to be run where the Buildkite CLI (`bk`)
has an API token. Jobs whose agent reported `agent_stop`, on the host or in a
KVM guest, can be retried at once; the others (agents or guests that had to be
killed, or whose stop was not confirmed) only once Buildkite shows them failed,
which for a lost agent takes about four minutes. A job whose agent had not been launched yet (the scheduler then no
longer launches it) is listed as reservation only: Buildkite schedules it again
once the reservation expires. One whose agent was launched but not running may
or may not have acquired the job, and is listed on its own. Slots the stop left
held, with a job that had ended but whose teardown failed, are listed last. If the scheduler was killed before writing the report, the commands
fall back to the jobs that were running in its last status snapshot, to be
checked in Buildkite first. Jobs that were only reserved return to the queue
without a retry. `restart` preserves the existing service definition;
`reinstall` regenerates it and reruns host setup before starting the scheduler.
On macOS, `disable` also removes the caffeinate and coredump launchd services
installed by `enable`.


## Configuration

Create a `config.toml` containing `[scheduler]` and one or more runner groups.
Examples live under `platforms/<platform>/`. Unknown keys are errors, so a typo
stops the scheduler from starting instead of being ignored.

### Scheduler

- `logdir`: Scheduler state and job logs; supports relative and `@scratch/`
  paths.
- `total_cpus`: Host CPU pool size (default and maximum: all logical CPUs). On
  macOS this is how wide each untagged job runs. The default counts the efficiency
  cores of Apple Silicon too, which Julia 1.10's `Sys.CPU_THREADS` leaves
  out; set it to the cores above the efficiency level instead (4 performance
  cores on M1 and M2, 2 super + 4 performance on M6).
- `total_mem_gib`: Host memory budget in GiB for jobs (default: physical
  memory), against which their memory requests and KVM guest reservations are
  charged. It is a workload budget, not the installed memory: leave room for
  the OS and the scheduler. On Macs, where an untagged job is told it has all
  of it, set it below physical memory: 6 on 8 GiB, 13 on 16 GiB, 20 on 24 GiB.
- `min_mem_available_gib`: Admit no job while the host's `MemAvailable` is below
  this many GiB (Linux only; default: 5% of physical memory, rounded up and kept
  below `total_mem_gib`; `0` disables it). Requests are what jobs typically use
  and limits overcommit, so when jobs peak at the same time this floor stops
  further admission; it cannot shrink jobs already running. Set it only to
  change that margin.
- `io_accounting`: Enable the io controller for Linux job cgroups, so their
  resource records have `io.stat`'s bytes and operations (default: `true`).
  It sets no limits or weights, but is not free of effects: with the BFQ I/O
  scheduler, jobs share a disk in proportion to their (equal) default weights,
  and cgroup writeback attributes each job's dirty pages to it. Set it to
  `false` and restart the scheduler if a host's kernel handles that badly
  (e.g. slow teardown after many jobs are killed): at startup, once stale job
  cgroups are gone, the scheduler disables io for job cgroups created from
  then on. If the kernel refuses, it logs an error and reports
  `io_accounting_stuck` in its status and the `sba_io_accounting_stuck` metric.

- `metrics_dir`: node_exporter textfile directory for the scheduler's metrics
  (default: unset, no metrics; see [Metrics](#metrics)).

Cache retention (see [Cache retention](#cache-retention)) is configured per
filesystem holding a `cachedir`, `tempdir`, `sharedcache` or `persistence_dir`:

- `disk_high_water_percent`: Evict idle pools when a filesystem's use, as `df`
  reports it, is above this (default: `85`).
- `disk_low_water_percent`: Evict down to this (default: `75`).
- `disks`: Overrides of these two per filesystem, as tables keyed by any
  absolute path on it, without the `disk_` prefix:

  ```toml
  [scheduler.disks."/srv"]
  high_water_percent = 80
  ```
- `cache_max_age_days`: Reset pools this old, staggered over its last quarter
  (default: `14`; `0` never).
- `cache_retired_days`: Evict first the pools of pipelines that used no pool on
  this host for this long (default: `7`).
- `ccache_max_size_gb`: `max_size` written into shared pools' ccache
  configuration, in GB (default: `50`; `0` leaves it alone).
- `disk_check_interval`: Seconds between free-space checks (default: `60`).
- `cache_retention`: Set to `false` to stop evicting, resetting and removing slot
  leftovers; pools are still stamped and leased (default: `true`).

Advanced options are `poll_interval` (15 seconds), `error_sleep` (10 seconds),
`reservation_expiry_seconds` (300 seconds), and `assignment_timeout_seconds`
(12 hours).

### Metrics

With `metrics_dir` set, the scheduler writes
`<metrics_dir>/sandboxed_buildkite_agent.prom` for node_exporter's textfile
collector. The status heartbeat (at most every 30 seconds) writes it from the
same snapshot as `scheduler-status.json`, atomically; a clean shutdown removes
it. A failing write is logged and does not stop
scheduling. Only this host's own state is exported, without a host
label (the scrape adds `instance`); the `_total` cache metrics are counters:

| Metric | Labels | Meaning |
|---|---|---|
| `sba_cpus_capacity`, `sba_cpus_allocated` | | `total_cpus`, and the CPUs charged to running jobs |
| `sba_mem_gib_capacity`, `sba_mem_gib_allocated` | | `total_mem_gib`, and the GiB charged to running jobs (memory requests; KVM guest RAM plus overhead) |
| `sba_memory_braked` | | 1 while `MemAvailable` is below `min_mem_available_gib` |
| `sba_jobs_running` | `group`, `queue` | slots holding a job (setup and cleanup included), by the job's queue |
| `sba_slots_used` | `group` | leased slots: running jobs, including quarantined ones |
| `sba_slots_created` | `group` | slots made since the scheduler started (at least 1): the most the group leased at once |
| `sba_slots_max` | `group` | `max_slots`, only for groups that set it |
| `sba_group_blocked` | `group` | 1 when a job of the group waits for resources (or behind one that does), or the backend is unavailable |
| `sba_io_accounting_stuck` | | 1 when `io_accounting` is off but Linux job cgroups still get the io controller |
| `sba_cache_pools`, `sba_cache_pools_leased` | | pools on disk at the last sweep, and pools held by jobs |
| `sba_cache_evictions_total`, `sba_cache_resets_total`, `sba_cache_leftovers_removed_total`, `sba_cache_removal_failures_total` | | counters since the scheduler started |
| `sba_scheduler_info` | `version` (git commit) | constant 1 |

Filesystem size and free space are not exported here: node_exporter's
`node_filesystem_size_bytes` and `node_filesystem_avail_bytes` report them.

The file is not refreshed while the scheduler is down, so readers should check
its age with node_exporter's `node_textfile_mtime_seconds` and ignore it when it
is older than a couple of minutes. Linux node_exporter packages read
`/var/lib/prometheus/node-exporter` (the directory must be writable by the
scheduler's user); on macOS, start node_exporter with
`--collector.textfile.directory=<dir>`.

### Runner groups

- `queues`: Buildkite queues served by the group, as an array or a
  comma-separated string (default: `["build", "test"]`). Each queue gets its own
  Stack, `julia-<group>-<queue>-<host>` (`julia-<group>-<host>` for a group with
  one queue).
- `default`: Table with the size of jobs whose step sets no `sched_*` tags, with
  the same requests and limits as the tags: `cpus`, `cpus_limit` (default:
  `cpus`), `mem_gib` (default: 0, which charges no memory) and `mem_limit_gib`
  (default: `mem_gib`, 0 being unlimited on Linux; KVM needs one of the two);
  on Linux, `cpus = 0` charges no CPUs. A table per
  queue, such as `[linux.default.build]`, overrides it for that queue; each such
  table is a complete size and inherits nothing from the group's. Without a
  `default` for its queue, an untagged job is failed. Tags always override the
  default. Not available on macOS, where an untagged job always gets the whole
  host (`cpus = cpus_limit = total_cpus`, `mem_gib = mem_limit_gib = total_mem_gib`).

  ```toml
  [linux.default.build]
  cpus = 4
  cpus_limit = 16
  mem_gib = 40
  [linux.default.test]
  cpus = 12
  mem_gib = 64
  ```

  Untagged jobs that typically use far less than their peak are charged the
  former and limited to the latter:

  ```toml
  [yggy.default]
  cpus = 16
  mem_gib = 32        # charged against total_mem_gib
  mem_limit_gib = 96  # memory.max
  ```
- `max_cpus`, `max_mem_gib`: KVM only; caps on the vCPUs and guest RAM a
  tagged step can get. These are facts about the host and image, not policy.
- `max_slots`: The most jobs of the group that run at once. A slot is a
  persistent worker identity: the agent name, cache pools, scratch directories
  and on KVM the domain name and cache disks. A job takes the lowest free slot,
  so warm caches are reused, and a new slot is made only when every existing one
  is busy. A group whose untagged jobs are all charged CPUs or memory (every
  KVM and macOS group, and any Linux group whose `default` tables set `cpus` or
  `mem_gib`) needs no `max_slots`: the host's CPUs and memory bound it. A Linux
  group with an uncharged `default` (`cpus = 0` and no `mem_gib`, such as a
  launcher) must set it, since nothing else bounds it. Cache pools of slots that
  stop being used age out through [Cache retention](#cache-retention).
- `priority`: Admission priority; lower values run first (default: `10`). Only
  needed for groups that must jump the queue, such as launchers.
- `min_job_age`: Seconds a job must have been runnable on Buildkite (its
  `runnable_at`, when the steps it depends on finished) before this group takes
  it (default: `0`). Hosts serving the same queue have no shared scheduler;
  giving slower hosts a delay lets idle faster hosts take each job first, while
  the slower ones still take whatever the faster ones leave. Jobs are only seen
  once per poll, so the effective delay is rounded up to `poll_interval`; keep
  it well above that, and expect a few seconds of host clock skew.
- `backend`: `linux-sandbox`, `macos-seatbelt`, or `kvm` (default: native).
- `guest`: KVM guest, either `windows` or `freebsd`.
- `platform`: BinaryPlatforms triplet (default: host platform).
- `tags`: Additional Buildkite agent tags. The scheduler adds `os` and `arch`
  (from the platform, or the KVM guest), `config_gitsha`, `cpuset_limited` where
  every job runs in a cpuset, `macos_version` on macOS (`26.1`), and `cpu`: the
  host's CPU model as libuv reports it, lower case, with runs of other
  characters than letters and digits turned into `-` (`apple-m2`,
  `amd-ryzen-9-9950x-16-core-processor`, `neoverse-n1`). KVM groups get the
  host's `cpu`, since their vCPUs run on it. Steps that need one CPU model,
  such as benchmarks, require it with `cpu: "apple-m2"` in their `agents`. A
  tag set here wins over a derived one, except `macos_version` and
  `cpuset_limited`.
- `tempdir`, `cachedir`: Temporary and worker-local cache roots. The scheduler
  deletes pools and slot directories it finds in them (see
  [Cache retention](#cache-retention)), so they must not be shared with another
  scheduler.
- `sharedcache`: Optional Linux-only compiler-cache root.
- `persistence_dir`: Linux only: where jobs' writable overlay layers go (each
  slot's `persist-<slot>` directory, wiped between jobs and mounted at
  `/persist` for nested sandboxes), when the default next to `cachedir` lacks
  the room or the filesystem features overlayfs needs.
- `secrets_dir`: Directory containing `buildkite-agent-token` (default:
  `agent/secrets`); see [`agent/secrets/README.md`](agent/secrets/README.md).
- `verbose`: Enable verbose backend output.

An advanced option is `stack_key`.


## Images

Linux uses Julia artifacts and macOS uses host toolchains. KVM images are built
locally. Create `agent/secrets/credentials.pkrvars.hcl` with a `password` value,
then run:

```
cd platforms/windows-kvm  # or platforms/freebsd-kvm
make validate
make all
```

`make base` and `make worker` build the layers individually. See the
[Windows](platforms/windows-kvm/README.md) and
[FreeBSD](platforms/freebsd-kvm/README.md) documentation for details.


## Host storage mounts

If scheduler storage lives on a separate Linux filesystem, add a host-local
systemd dependency so everything is mounted before the agent starts. For example:

```sh
unit=sandboxed-buildkite-agent.service
sudo install -d -m 0755 "/etc/systemd/system/${unit}.d"
sudo tee "/etc/systemd/system/${unit}.d/storage-mount.conf" >/dev/null <<'EOF'
[Unit]
RequiresMountsFor=/julia
EOF
sudo systemctl daemon-reload
systemctl show "$unit" -p Requires -p After
```

Replace `/julia` with the host's mountpoint. The drop-in survives
`bin/sba disable && bin/sba enable`.
