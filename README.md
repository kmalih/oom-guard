# oom-guard

Reap **idle worker processes** before they OOM-hang a small box.

On a memory-constrained host (a 1 GB VPS, a `t3.micro`, a Raspberry Pi), long-lived
worker processes that sit idle slowly accumulate RAM. Eventually the machine runs
out of memory, starts thrashing swap, and **freezes** — an out-of-memory (OOM) hang.

`oom-guard` watches a process you choose and kills workers that have been **idle**
(near-zero CPU) for too long, freeing that memory before it becomes a problem. A
client can just reconnect to spawn a fresh worker.

## How "idle" is decided

Each run samples every matching process's cumulative CPU time from `/proc/<pid>/stat`.
A worker counts as idle when its **CPU rate since the last sample** is below
`IDLE_RATE` ticks/sec. Stay idle continuously for `IDLE_SECS` and it gets `SIGTERM`,
then `SIGKILL` after a short grace period. PID reuse is handled via the process
`starttime`, so a recycled PID never inherits another process's idle clock.

It only ever signals processes matching `PROC_PATTERN` (exact name, via `pgrep -x`),
so a **parent daemon with a different name is never touched**. No root required — it
only reads `/proc` and kills processes the running user already owns.

## Install (per-user systemd timer, no root)

```sh
git clone https://github.com/kmalih/oom-guard.git
cd oom-guard
PROC_PATTERN=my-worker ./install.sh
```

Runs every 5 minutes. Check it:

```sh
systemctl --user status oom-guard.timer
cat ~/.local/state/oom-guard/oom-guard.log
```

## Configuration

Set as environment variables (in the service file, or when running by hand):

| Variable       | Default      | Meaning                                            |
|----------------|--------------|----------------------------------------------------|
| `PROC_PATTERN` | `claude.exe` | Exact process name to reap when idle (`pgrep -x`)  |
| `IDLE_SECS`    | `1800`       | Seconds of continuous idle before reaping (30 min) |
| `IDLE_RATE`    | `2.0`        | CPU ticks/sec below this counts as idle            |
| `GRACE_SECS`   | `10`         | Seconds to wait after `SIGTERM` before `SIGKILL`   |
| `DRY_RUN`      | `0`          | `1` logs decisions but kills nothing               |

### Dry run first

See what it *would* do without killing anything:

```sh
DRY_RUN=1 PROC_PATTERN=my-worker ~/.local/bin/oom-guard.sh
cat ~/.local/state/oom-guard/oom-guard.log
```

## Notes

- Born from keeping `claude remote-control` worker sessions from OOM-hanging a
  1 GB instance — hence the default `PROC_PATTERN`. Point it at anything.
- Pair it with [`earlyoom`](https://github.com/rfjakob/earlyoom) as a hard
  emergency brake: `oom-guard` does scheduled idle cleanup, `earlyoom` kills a
  runaway process instantly if memory fills up between runs.

## License

MIT
