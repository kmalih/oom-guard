# oom-guard

Reap worker processes **under memory pressure** before they OOM-hang a small box.

On a memory-constrained host (a 1 GB VPS, a `t3.micro`, a Raspberry Pi), long-lived
worker processes can pile up — an abandoned session, or the brief overlap when a
client reconnects — until the machine runs out of memory, starts thrashing swap,
and **freezes**: an out-of-memory (OOM) hang.

`oom-guard` watches **free RAM**. When `MemAvailable` drops below a threshold it
kills the **idlest** matching worker first, re-checks memory after each kill, and
stops as soon as memory recovers. The single **most-active worker is always
protected**, so your live session survives while abandoned or overlapping ones are
cleared. A client can just reconnect to spawn a fresh worker.

> **Why memory, not idle time?** An earlier version of this tool reaped any worker
> that had been idle for 30 minutes. That equates "idle" with "abandoned" — so a
> session you'd merely stepped away from got killed silently, and it never reacted
> fast enough to a real RAM spike (e.g. a reconnect overlap that fills memory in
> seconds). This version fixes both: it acts on the actual signal (memory) within
> the timer interval, and never kills the worker you're actively using.

## Does this solve your problem?

You're in the right place if any of these sound familiar:

- My **VPS freezes / hangs when it runs out of memory** and I have to reboot it.
- A **`t3.micro` / 1 GB server keeps locking up** under memory pressure.
- Worker processes **pile up and exhaust RAM** (abandoned sessions, reconnect overlap).
- I want to **kill only child workers, not the parent daemon** (the supervisor
  should keep running so clients can reconnect).
- I need an **`earlyoom` alternative (or companion)** that reaps *idle* workers
  under pressure and protects the active one, instead of killing by raw RSS.
- I'm running **long-lived workers (browser/headless, language-server, agent, RPC,
  remote-control sessions) on a small box** and they OOM-hang it.

It is a lightweight, dependency-free, **no-root** Bash + systemd timer — not a
daemon, not a framework.

## How it decides what to kill

Each run reads `MemAvailable` from `/proc/meminfo`. If it's above `MEM_MIN_KB`,
oom-guard does nothing. Under that threshold it:

1. Samples every matching process's CPU twice, `SAMPLE_SECS` apart, to rank them
   by how **idle** they are right now (lowest CPU rate = idlest).
2. **Protects the single most-active worker** (your live session) — it is never a
   victim. A brand-new worker with no measured activity is treated as active.
3. Kills the **idlest** worker, waits `GRACE_SECS`, escalates `SIGTERM`→`SIGKILL`,
   then re-checks memory and repeats until `MemAvailable` ≥ `MEM_TARGET_KB`.

It only ever signals processes matching `PROC_PATTERN` (exact name, via `pgrep -x`),
so a **parent daemon with a different name is never touched**. No root required — it
only reads `/proc` and kills processes the running user already owns.

If memory is critically low but the *only* worker present is the active one,
oom-guard reaps nothing and logs that the host is undersized — it can't free RAM it
isn't allowed to take, so the real fix there is a bigger host.

## Install (per-user systemd timer, no root)

```sh
git clone https://github.com/kmalih/oom-guard.git
cd oom-guard
PROC_PATTERN=my-worker ./install.sh
```

Runs every minute (only does real work when memory is tight). Check it:

```sh
systemctl --user status oom-guard.timer
cat ~/.local/state/oom-guard/oom-guard.log
```

## Configuration

Set as environment variables (in the service file, or when running by hand):

| Variable         | Default      | Meaning                                                       |
|------------------|--------------|---------------------------------------------------------------|
| `PROC_PATTERN`   | `claude.exe` | Exact process name to reap (`pgrep -x`)                       |
| `MEM_MIN_KB`     | `120000`     | Reap when `MemAvailable` falls below this (~120 MB)           |
| `MEM_TARGET_KB`  | `200000`     | Stop reaping once `MemAvailable` recovers past this (~200 MB) |
| `PROTECT_ACTIVE` | `1`          | `1` = never kill the single most-active worker               |
| `SAMPLE_SECS`    | `3`          | CPU sampling window used to rank workers by idleness         |
| `IDLE_RATE`      | `2.0`        | CPU ticks/sec below which a worker counts as "idle"          |
| `GRACE_SECS`     | `10`         | Seconds to wait after `SIGTERM` before `SIGKILL`             |
| `IDLE_SECS`      | `0`          | `>0` also reaps workers idle this long, *regardless* of RAM   |
| `DRY_RUN`        | `0`          | `1` logs decisions but kills nothing                         |

### Dry run first

Force the memory path and see what it *would* do without killing anything:

```sh
DRY_RUN=1 MEM_MIN_KB=999999999 PROC_PATTERN=my-worker ~/.local/bin/oom-guard.sh
cat ~/.local/state/oom-guard/oom-guard.log
```

## Notes

- Linux-only by design — it reads `/proc/meminfo` and `/proc/<pid>/stat`.
- Born from keeping `claude remote-control` worker sessions from OOM-hanging a
  1 GB instance — hence the default `PROC_PATTERN`. Point it at anything.
- Pair it with [`earlyoom`](https://github.com/rfjakob/earlyoom) as a hard
  emergency brake: `oom-guard` clears the idlest worker under pressure while
  protecting the active one; `earlyoom` kills a runaway process instantly if
  memory fills faster than the timer interval.

## License

MIT
