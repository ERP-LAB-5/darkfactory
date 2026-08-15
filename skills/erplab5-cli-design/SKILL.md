---
name: erplab5-cli-design
description: House rules for the ERP-LAB-5 Python operator tools (sap-di-autopilot, sap-cc-operator) — read a system at the level the question needs instead of always doing a full scan, accept `--` arguments for batch use while opening a menu when invoked bare, and never let a configuration file name a default system. Use when adding or changing a CLI entry point, adding argparse flags or an interactive prompt, deciding how deep to fetch from a monitoring API, wiring a script into a container or CronJob, or when a tool "takes minutes just to tell me if it is running", asks nothing when it should, or blocks on a prompt in a scheduled run.
---

# ERP-LAB-5 — CLI and read-depth design

Two rules, both learned the same way: the tool was doing more work than the
question needed, and deciding things for the operator that the operator should
have decided.

## 1. Read at the level of the question

Monitoring APIs for replication or connectivity nest levels — a flow holds
tasks, a task holds partitions; a connector holds tunnels, a tunnel holds
resources. A read should stop at the level that answers the question.

The trap is that the deep read is written first, because the analytical use case
(classify every error message) needs it, and then everything else inherits it. On
a real tenant a full walk is one call per flow plus one, and takes minutes. "Is
this flow healthy?" and "what could I resume?" are answered at the top level from
a single call.

Before adding a read, establish **what the API actually offers**, not what would
be convenient:

- A summary endpoint that returns every object with counts in one call is the
  big saving. In SAP DI RMS that is `GET /replicationflowMonitors`, with
  `taskMetrics` per flow.
- Check whether the detail endpoint can return *less*. Usually it cannot — RMS
  `taskMonitors` always includes partitions. Then the only remaining lever is
  **calling it for fewer objects**, and the honest description of the middle
  level is "the same call, over a narrower set, read out more shallowly".

Do not write help text claiming a level is cheaper than it is. An operator who
finds out that `--level task` costs the same as `--level partition` on the same
flows stops believing the rest of the output.

Concretely:

- One module owns depth and object selection. Every caller goes through it —
  no second path that hits the client directly for a partial read.
- The middle level defaults to the objects that are **not healthy**; a flag
  widens it to everything, a name narrows it to one.
- Serve the same levels from a cached snapshot with no credentials. A snapshot
  usually stores the detail, not the summary, so derive the summary back out of
  it into the identical shape. A cached view must not be shaped differently from
  a live one.
- **Every view names the command for the level below it**, targeting something
  that actually had a finding rather than the first item alphabetically:

  ```
    N flow(s), M not healthy — <task counts by state>
    Deeper: status.py --sid <SID> --level task
  ```

  That is what makes levels usable: the operator walks down and pays only for
  what they open.
- Acting follows the same shape. An interactive suspend/resume walk starts at the
  summary level and opens one object's detail only when asked to.

## 2. Flags for batch, a menu when bare

Every entry point takes `--` arguments for scripted use, and opens a menu when
invoked with no arguments at all.

```python
def wants_menu(args, bare, interactive):
    if args.no_menu:
        return False
    if args.menu or bare:      # bare wins over `interactive` on purpose
        return True
    if args.sid:
        return False
    return interactive
```

`bare` is `not sys.argv[1:]`; `interactive` is `sys.stdin.isatty()`.

| Invocation | Terminal | PyCharm / pipe / cron |
|---|---|---|
| bare | menu | **menu** |
| `--menu …` | menu | menu |
| `--sid X …` | no menu | no menu |
| other flags, no `--sid` | menu | no menu |
| `--no-menu` | no menu | no menu |

The two rows that matter:

- **A bare invocation prompts even when stdin is not a tty.** No arguments means
  a person is driving. This is what makes the scripts usable in PyCharm, whose
  run console accepts `input()` but is not a terminal — otherwise every developer
  has to configure "emulate terminal" before anything works.
- **A run that passed flags never blocks on a prompt.** It needs a real terminal
  or an explicit `--menu`, so a scheduled job cannot stall waiting for an answer
  nobody will give.

In a container this cuts both ways: a bare `docker run` would open the menu, hit
EOF on non-tty stdin, print "Cancelled." and exit **0** — a scheduled job that
does nothing and reports success. Put `--no-menu` in the image's `CMD` and say in
a comment why it is not optional.

Shared flags (`--sid`, `--config`, `--offline`, `--log-level`, `--menu`,
`--no-menu`) come from one `add_common_arguments()`. One system picker, shared,
with a hook for per-script columns. Each script keeps its own remaining questions
next to the work they configure.

## 3. No default system in a config file

The target system comes from an argument, an environment variable, or the menu.
Never from the configuration file.

A stored "active system" is invisible at the moment it matters. It gets written
once in one context — a labelling session, a demo — and then silently decides
what an unattended run does weeks later. Preprod and production differ by a few
characters, and the run that goes to the wrong one says nothing.

So a run that cannot determine its target stops, naming every way to give it one:

```
No system given. Pass --sid <SID>, export DI_SID, or run monitor.py with no
arguments for the menu.
  Known systems: <SID>, <SID2>
```

Exit 2 — a scheduled job that fails loudly beats one that quietly aims at the
wrong tenant. The container passes the environment variable; the CronJob passes
the argument. Nothing writes the configuration file back; switching target inside
an interactive tool changes that session only.

The same holds for anything else with a blast radius: an allowlist of systems a
write may target, plus an explicit `--execute`, plus a typed-back confirmation.
Two keys, and neither of them a remembered default.

### And no preconfigured systems either

Take it one step further: the committed template should carry **no systems at
all** — not even placeholders with empty credentials. Ship the policy and the
client settings, and let a `systems.py` ask on first run how many systems to
manage and walk each one, with add / edit / remove / list afterwards.

Two things fall out of it, and both matter more than the small amount of code:

- **Nothing in the repository names a landscape.** Example SIDs in a template
  are how a customer's system ids end up in a public diff. Write `<SID>` in
  documentation and let the operator supply the real one.
- **A fresh checkout cannot be aimed at anything by accident.** A template with
  a real URL and blank credentials is one `export` away from live.

The catch, and it is easy to miss: emptying the template breaks any env-only
deployment that relied on those blocks existing for `DI_<SID>_*` to override.
Scan the environment for the marker variable (the base URL) and synthesise the
system from it, so a container with a secret and no mounted file still works —
then show such systems in the listing as coming from the environment, and refuse
to edit or remove them, because the file is not where they live.

### Names an entry point may not have

Do not call it `setup.py`. At a project root that name is the setuptools build
script, so `pip install .` and legacy `python setup.py <command>` would execute
your wizard as a build step. It is inert until someone adds packaging, and inert
is not the same as correct — rename it before that, not after. The same applies
to `conftest.py`, `test_*.py`, `sitecustomize.py` and `__main__.py`.

Name entry points for **what they show**, not what they do to the configuration:
`status.py`, `throughput.py`, `incidents.py`, `systems.py`. A verb ages badly as
a command grows — the file that only added a system ends up editing, removing and
listing them too.

## Entry-point shape

```python
def main(argv=None):
    args = parse_args(argv)

    try:
        cfg = config.load(args.config)      # config first, cheaply
    except config.ConfigError as exc:
        print(f"Configuration error: {exc}", file=sys.stderr)
        return 2

    from src import menu                    # heavy imports only after that

    if menu.opens(args, argv):
        selection = ask_selection(cfg)      # this script's own questions
        if selection is None:
            print("\nCancelled.\n")
            return 0
        args.sid = selection["sid"]

    try:
        cfg, sid = config.bootstrap(args, script="status.py")
    except config.ConfigError as exc:
        print(f"\n{exc}\n", file=sys.stderr)
        return 2
    ...
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Exit codes suit a scheduler. Findings are not failures — a run that finds 200
broken partitions still exits `0`:

| Code | Meaning |
|---|---|
| `0` | it ran, whatever it found |
| `2` | configuration, snapshot, or a named target that does not exist |
| `1` | unexpected failure |
| `130` | interrupted |

A menu question says **why** an option is unavailable rather than hiding it
("no credentials", "no snapshot stored yet", "not in live_sids"), and anything
that changes a live system asks for a confirmation that cannot be typed by
accident — the system id or the verb, echoed back.

## Related

- `~/ERP-LAB-5/sap-di-autopilot/docs/cli-design.md` — the same rules with this
  project's file names and the reasoning behind each
- `~/ERP-LAB-5/sap-di-autopilot/src/scan.py` — the level-aware read
- `~/ERP-LAB-5/sap-di-autopilot/src/menu.py` — `wants_menu`, `opens`, `choose_sid`
- `sap-di-rms-api` skill — which RMS endpoint answers at which level
