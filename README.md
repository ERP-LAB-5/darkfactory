# darkfactory

Shared **Claude Code skills** for the ERP-LAB-5 projects. One version-controlled
copy of each skill, symlinked into the projects that need it — so a correction
made while working on `sap-di-autopilot` is immediately true for `sap-cc-operator`
as well, and none of it lives only in an untracked `~/.claude` directory.

## Skills

| Skill | What it covers | Linked into |
| --- | --- | --- |
| [`sap-cc-operations`](skills/sap-cc-operations/) | SAP Cloud Connector: the admin REST API (monitoring is **not** under `/api/v1`), the two first-run 403s, the trace format, and working through `NoChannelsAvailableException` | `sap-cc-operator` |
| [`sap-di-rms-api`](skills/sap-di-rms-api/) | SAP Data Intelligence RMS internal API — replication flows, task monitors, start/resume/suspend. The public DI API does not cover RMS at all | `sap-di-autopilot` |
| [`erplab5-cli-design`](skills/erplab5-cli-design/) | House rules for the Python operator tools — read a system at the level the question needs, `--` arguments for batch with a menu when called bare, and no default system in a config file | `sap-cc-operator`, `sap-di-autopilot` |
| [`erplab5-security-audit`](skills/erplab5-security-audit/) | Eight-domain audit across BTP (destinations, role collections, service keys, Kyma), the Cloud Connector boundary, and NetWeaver on-prem (gateway ACLs, ICF, default users, critical auth objects, audit log) — plus the repo sweep that runs before any push | `sap-cc-operator`, `sap-di-autopilot` |
| [`git-commit`](skills/git-commit/) | Commit conventions across DLAB5 and ERP-LAB-5 — subject convention per repo, the body shape with its verification block, the two sign-off trailers | `~/.claude` (machine-wide) |

## How the wiring works

`skills/` holds the real files. Everything else is a symlink to it.

```
darkfactory/skills/sap-cc-operations/SKILL.md          <- the only real copy

sap-cc-operator/.claude/skills/
  sap-cc-operations -> ../../../darkfactory/skills/sap-cc-operations

sap-di-autopilot/.claude/skills/
  sap-di-rms-api    -> ../../../darkfactory/skills/sap-di-rms-api

~/.claude/skills/
  git-commit        -> ~/ERP-LAB-5/darkfactory/skills/git-commit
```

Two placements, chosen per skill:

- **Project-scoped** (`<project>/.claude/skills/`) for skills that only make
  sense inside one project. Relative links, so they survive the whole
  `ERP-LAB-5` tree being moved or cloned elsewhere.
- **Machine-wide** (`~/.claude/skills/`) for `git-commit`, which applies to every
  repo on this workstation — including the DigitalHome.Cloud ones outside
  ERP-LAB-5. Linking it here rather than copying keeps one source of truth.

A skill must not be linked into both at once for the same project — Claude Code
would see the name twice.

Run `./link-skills.sh` to create or repair every link, and
`./link-skills.sh --check` to verify without changing anything. It is idempotent
and refuses to overwrite a real (non-symlink) directory.

## This repo is public

**Everything committed here is world-readable**, and so is `sap-di-autopilot`;
only `sap-cc-operator` is private. Skills and their projects are written while
working against real systems, so they attract real identifiers — that is the
whole risk.

| Repo | Visibility |
| --- | --- |
| [`darkfactory`](https://github.com/ERP-LAB-5/darkfactory) | **public** |
| [`sap-di-autopilot`](https://github.com/ERP-LAB-5/sap-di-autopilot) | **public** |
| [`sap-cc-operator`](https://github.com/ERP-LAB-5/sap-cc-operator) | private |

Check before you assume — `gh repo view ERP-LAB-5/<name> --json visibility`.
This table was wrong for a while, claiming `sap-di-autopilot` had no remote at
all, which is exactly how landscape identifiers end up in a public diff.

Before committing a skill, scrub:

- **Tenant, subaccount and system ids** — `dh-*` DI tenants, BTP subaccount ids,
  SID-plus-landscape pairs. Replace with a placeholder or a shape (`{tenant}`,
  "a DI 3.x preprod tenant"). The endpoint paths and auth forms are the valuable
  part and none of them are secret.
- **Hostnames and usernames** of real systems. Use `scc-prod-01`,
  `default\di-support` — plausible shapes, not the actual ones.
- **Object counts that fingerprint a landscape** — "125 flows / 1263 tasks" says
  more about a customer than it teaches the reader. Round it or drop it.
- **Anything from a customer log**: internal hostnames, backend system ids,
  account names.

Credentials should never be near a skill in the first place. A quick sweep:

```bash
grep -rnIE '(AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|dh-[a-z0-9]{8,})' skills/
```

If a skill genuinely cannot be written without a real identifier, it does not
belong in darkfactory — keep it in the private repo it describes.

## Adding a skill

1. `mkdir skills/<name>` and write `SKILL.md` with `name:` and `description:`
   frontmatter. The description is what Claude matches against, so make it list
   the phrases and error strings that should trigger it — not just a topic.
2. Add a row to the `LINKS` table at the top of `link-skills.sh`.
3. `./link-skills.sh`
4. Scrub it against the list above.
5. Commit. The skill is now shared rather than sitting in someone's `~/.claude`.

Write down what was **hard to find**: exact endpoint paths, the response body of
a confusing error, the flag that silently no-ops, version-dependent file names.
A skill that restates the obvious costs context and earns nothing.

## Related

- [`sap-cc-operator`](https://github.com/ERP-LAB-5/sap-cc-operator) — SAP Cloud
  Connector tooling
- `sap-di-autopilot` — SAP Data Intelligence replication-flow auto-healer
- `~/digitalhomeCloud/digitalhome-cloud-darkfactory` — the DigitalHome.Cloud
  equivalent. Its skills (`dhc-amplify-gen2`, `dhc-security-audit`,
  `dhc-device-autodiscovery`, `dhc-electrical-installation-design`) are tied to
  the Gatsby/Amplify platform and are deliberately **not** duplicated here;
  `design-implement` stays machine-wide in `~/.claude/skills`.
