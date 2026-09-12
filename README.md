# darkfactory

**The ERP-LAB-5 plugin catalogue**, and the shared Claude Code skills it owns.

One version-controlled copy of each shared skill, delivered as plugins so any
machine can install them — not just the one where this repository happens to be
checked out.

```
/plugin marketplace add ERP-LAB-5/darkfactory
/plugin install erplab5-house@erp-lab-5
```

## What is in the catalogue

An entry is a **pointer**. Three plugins live here; the rest live in the
repository that owns them, so nobody waits on this repo to ship a change.

| Plugin | What you get | Lives in |
| --- | --- | --- |
| [`erplab5-house`](plugins/erplab5-house/) | `git-commit` (commit conventions and trailers), `erplab5-cli-design` (house rules for the Python operator tools), `erplab5-security-audit` (eight domains across BTP, the Cloud Connector and NetWeaver, plus the pre-push repo sweep) | here |
| [`sap-cc-operations`](plugins/sap-cc-operations/) | SAP Cloud Connector: the admin REST API and where monitoring really lives, the two first-run 403s, the trace format, `NoChannelsAvailableException` | here |
| [`sap-di-rms-api`](plugins/sap-di-rms-api/) | SAP Data Intelligence RMS internal API — replication flows, task monitors, start/resume/suspend. The public DI API does not cover RMS at all | here |
| `pytool-kit` | Building D-LAB-5 Python tools: scaffold from the template, extend through every layer, take core fixes, release | [python-tool-template](https://github.com/ERP-LAB-5/python-tool-template) |
| `di-replication-sync` | Compare and promote DI replication flows between landscapes (skill only) | [sap-di-tools](https://github.com/ERP-LAB-5/sap-di-tools) |

Install only what a machine needs: `erplab5-house` everywhere, the SAP ones
where that work happens.

## Layout

```
.claude-plugin/marketplace.json          the catalogue: what exists and where
plugins/<plugin>/
  .claude-plugin/plugin.json             name, version, description
  skills/<skill>/SKILL.md                the only copy of that skill
```

There is still exactly one copy of every skill. What changed is that the copy
now sits inside a plugin, which is a shape other machines can install. Skill
directories hold real files, never symlinks: a symlink does not survive a clone
on Windows, and the subdirectory checkout used for cross-repo entries does not
carry one either.

## Working on a skill

Edit the file, then load it without publishing anything:

```bash
claude --plugin-dir ~/ERP-LAB-5/darkfactory/plugins/erplab5-house
```

That is the fast loop — the session picks up the working copy as it is on disk.
When it is good, publish:

1. bump `version` in that plugin's `.claude-plugin/plugin.json`
2. commit and push
3. consumers pick it up with `/plugin marketplace update erp-lab-5`

## Adding a skill

1. `mkdir -p plugins/<plugin>/skills/<name>` and write `SKILL.md` with `name:`
   and `description:` frontmatter. The directory name and the `name:` must
   match. The description is what Claude matches against, so list the phrases
   and error strings that should trigger it — not just a topic.
2. Put it in the plugin whose audience it fits, or start a new plugin with its
   own `plugin.json` and add an entry to `.claude-plugin/marketplace.json`.
3. Scrub it against the list below.
4. Bump the plugin version, commit, push.

Write down what was **hard to find**: exact endpoint paths, the response body of
a confusing error, the flag that silently no-ops, version-dependent file names.
A skill that restates the obvious costs context and earns nothing.

## Adding a plugin that lives somewhere else

Add one entry here; the files stay in their own repository, with their own
release cadence:

```json
{
  "name": "my-tool",
  "source": { "source": "git-subdir",
              "url": "https://github.com/ERP-LAB-5/my-tool.git",
              "path": "plugin" },
  "description": "…",
  "author": { "name": "D-LAB-5" }
}
```

That is the whole trick to keeping a shared catalogue from becoming a
bottleneck: the catalogue lists, it does not hold.

## This repo is public

**Everything committed here is world-readable.** Skills are written while
working against real systems, so they attract real identifiers — that is the
whole risk.

| Repo | Visibility |
| --- | --- |
| [`darkfactory`](https://github.com/ERP-LAB-5/darkfactory) | **public** |
| [`python-tool-template`](https://github.com/ERP-LAB-5/python-tool-template) | **public** |
| [`sap-di-tools`](https://github.com/ERP-LAB-5/sap-di-tools) | **public** |
| [`metro-map-tool`](https://github.com/ERP-LAB-5/metro-map-tool) | **public** |
| [`sap-di-autopilot`](https://github.com/ERP-LAB-5/sap-di-autopilot) | private |
| [`sap-cc-operator`](https://github.com/ERP-LAB-5/sap-cc-operator) | private |

Check before you assume — `gh repo view ERP-LAB-5/<name> --json visibility`.
This table has been wrong in both directions already, which is exactly how
landscape identifiers end up in a public diff.

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
grep -rnIE '(AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|dh-[a-z0-9]{8,})' plugins/
```

If a skill genuinely cannot be written without a real identifier, it does not
belong here — keep it in the private repo it describes, and list that repo's
`plugin/` directory as a catalogue entry instead. Only people with access to
that repo can install it.

## Other skill mechanisms on the same machine

Not everything under `~/.claude/skills` comes from here, and that is fine:

- **Vendored third-party skills.** `sap-di-autopilot` links ten `sap-btp-*`
  skills from `kone-SAP-PLF-lab-darkfactory/.agents/skills/`, tracked by
  `skills-lock.json` (source: `secondsky/sap-skills`). They are not ours to
  republish; leave them on their own mechanism.
- **`npx skills add owner/repo`** installs skills from any repository with a
  `SKILL.md`, straight into `~/.claude/skills`. Useful for outside skills; this
  catalogue is for ours.
- **DigitalHome.Cloud** keeps its own equivalent at
  `~/digitalhomeCloud/digitalhome-cloud-darkfactory`. Its skills are tied to the
  Gatsby/Amplify platform and are deliberately not duplicated here.

## Licence

MIT. See [LICENSE](LICENSE).
