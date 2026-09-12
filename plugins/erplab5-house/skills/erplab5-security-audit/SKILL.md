---
name: erplab5-security-audit
description: Security and quality audit for the ERP-LAB-5 landscape and its tooling — SAP BTP subaccounts (destinations, XSUAA role collections, service keys, trust, Kyma/CF), the Cloud Connector as the boundary between cloud and on-prem, and NetWeaver on-premise (RFC gateway ACLs, ICF services, default users, password policy, critical authorization objects, security audit log, SNC). Also sweeps the ERP-LAB-5 repos for secrets and landscape identifiers before they reach GitHub. Produces a severity-ranked report under docs/audits/. Use for "security audit", "is this landscape safe", "check our BTP posture", "audit the Cloud Connector", "review the RFC gateway", "who has SAP_ALL", "are we exposing too much on-prem", "check before I push this repo", or to pressure-test a design before it ships.
---

# SAP landscape — security and quality audit

## Why this exists

A BTP subaccount, a Cloud Connector and a NetWeaver system are three security
domains with three different tool sets, three different audit trails, and one
shared blast radius. The Cloud Connector is the seam: it is the only component
that deliberately punches a hole through the firewall, it is configured by
whoever installed it, and its access control list is the single most consequential
piece of configuration in the landscape — a `/` prefix resource on one system
mapping exposes every service on that host to the cloud.

The individual controls are all documented by SAP. What is not documented is the
**order to check them in and which ones actually bite**, which is what this skill
is for.

Run it quarterly, and ad-hoc whenever:

- A Cloud Connector is installed, upgraded, or its access control changes
- A BTP destination is added, or one moves from `PrincipalPropagation` to stored
  credentials
- A new RFC destination, ICF service, or gateway registration appears on-prem
- Before giving a tooling repo a git remote, or making one public
- After an SAP Security Patch Day that touches Gateway, ICM, ICF or the kernel

You can also invoke it mid-design ("would exposing this resource…?") — answer
inline against the relevant domain rather than writing a full report.

## Before you touch anything

Four ways this audit can itself cause an incident. All four are real.

1. **Repeated failed authentication locks the Cloud Connector Administrator
   account.** Recovery is to stop the JVM and restore `config/users.xml` from the
   archive — an outage. Never probe SCC credentials. Get them, or skip the API
   checks and read the config files instead.
2. **The SCC admin API is served by the JVM that carries your tunnel traffic.**
   Polling it during business hours competes with production RFC calls. Read-only
   is not the same as free.
3. **Raising the trace level on a production system** (SCC, or `ST01`/`RSAU` on
   NetWeaver) changes system behaviour and fills disks. If you need it, ask, agree
   a window, and put it back.
4. **`RSUSR003` and friends are reports, not changes — but `SU01`, `PFCG`, `SM59`
   and `RZ10` are one keystroke from being changes.** Use display mode. If you
   only have a dialog user with change authorization, say so in the report rather
   than "verifying" by modifying.

Read-only means: `GET` only against SCC and BTP APIs; display-mode transactions;
`SE16` browse, never `SE16N` in change mode; no `btp assign`, no `cf set-env`, no
`kubectl apply`. **Audit and report. Do not fix.** Remediation is a separate task
the user authorizes finding by finding.

## How to run

1. **Confirm scope.** Full (all eight domains) or targeted ("just the Cloud
   Connector", "just what we're about to push"). Ask which systems are in scope
   by SID and which are production — the severity of every finding depends on it.
2. **Snapshot what you are auditing.** SIDs and kernel patch levels, SCC version
   (`GET /api/v1/connector/version`), BTP subaccount ids, and `git log --oneline -1`
   per repo. A finding without a pinned version is not reproducible.
3. **Walk the domains in order.** 1 first — it is the only one that is fully
   automatable and it is where today's leak would be. Record findings as you go.
4. **Rank** with the rubric below.
5. **Write the report** to `docs/audits/YYYY-MM-DD-audit.md` in the repo the work
   belongs to. **If any repo in scope is public, write the report outside it** —
   an audit naming your posture gaps is not something to publish.
6. **Summarize Critical/High in chat** with counts per severity. Don't paste the
   whole report back.

## Severity rubric

| Severity | Meaning | SAP examples |
|---|---|---|
| **Critical** | Active exposure or imminent compromise. Within 24h. | Cloud Connector access control exposing `/` on a production host; `SAP*` with its default password in any client; gateway with no `reginfo`/`secinfo` reachable from an untrusted network; a service key or RFC password committed to a public repo; `S_RFC` with `RFC_NAME=*` on a dialog role. |
| **High** | Real risk, not yet exploited. Within a week. | Destination using stored `BasicAuthentication` to a production backend instead of principal propagation; SCC admin UI (8443) reachable beyond the admin network; Security Audit Log off, or on but nobody reads it; `SAP_ALL` on a named user in production; secret scanning disabled on a public repo. |
| **Medium** | Defensible, fix next cycle. | Password policy below the baseline; SNC off on internal RFC; trace level left at Debug; missing 2FA enforcement on the GitHub org; real tenant/system id in a tracked config template. |
| **Low** | Hygiene / defence in depth. | Unused RFC destinations left in `SM59`; ICF services active but unused; no branch protection; stale audit doc. |
| **Info** | Observation, not a defect. | Version inventory, counts, "checked and clean". |

Production weights up. The same finding on a sandbox is one level lower — say so
explicitly rather than silently de-ranking.

## The eight domains

### 1. Repository and secret hygiene

Always run this one. It is fully automatable and it is where a leak is both most
likely and most permanent — once a secret reaches a public repo it is compromised
even after deletion, because GitHub retains unreachable objects and the push event
is public. Rotate, don't just delete.

```bash
# Every repo in scope
for r in <repos>; do
  echo "########## $r ##########"

  # Files that must never be tracked
  git -C "$r" ls-files | grep -nEi \
    '\.env$|\.envrc|scc\.conf$|\.pem$|\.key$|\.p12$|\.jks$|id_rsa|credentials|\.netrc|secrets?\.(json|ya?ml)|\.pypirc|saprouttab|secinfo|reginfo'

  # Credentials in full history
  git -C "$r" log --all -p | grep -aE \
    'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN [A-Z ]*PRIVATE KEY'
  git -C "$r" log --all -p | grep -aEn \
    "^\+.*(password|passwd|secret|token|api[_-]?key|client_secret|hec_token)\s*[:=]\s*['\"][^'\"]{6,}" \
    | grep -avE 'password_env|newPassword|oldPassword|REPLACE_ME|EXAMPLE|<[a-z]|\{|\$'

  # SAP identifiers that fingerprint a landscape
  git -C "$r" log --all -p | grep -aoE \
    '\+.*(dh-[a-z0-9]{8,}|[a-z0-9-]+\.(dhaas-live|hana)\.[a-z0-9.-]*ondemand\.com|[a-z0-9-]+\.[a-z0-9-]+\.(corp|internal|local)\b)' \
    | sed 's/^+//' | sort -u

  # Routable IPs (RFC1918 filtered out)
  git -C "$r" log --all -p | grep -aoE '^\+.*\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
    | grep -aoE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | grep -avE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|0\.|255\.)' | sort -u
done
```

Beyond literal credentials, treat as findings:

- **Tenant, subaccount and system ids** — `dh-*` DI tenants, BTP subaccount GUIDs,
  SID-plus-hostname pairs. Not secret, but they name a reachable endpoint and
  confirm the landscape exists.
- **Object counts that fingerprint a landscape** — "125 flows / 1263 tasks" tells
  an outsider about a customer, and teaches a reader nothing.
- **Anything lifted from a production log**: internal hostnames, backend system
  ids, correlation ids, account names, table names. Masked corpora are fine —
  `[SAP_TABLE_NAME]`, `[ID]@[TIMESTAMP]` — and are the control that makes
  training data publishable.
- **Example files that are actually real.** `*.demo`, `*.example`, `*.template`
  are the *most* read and most copied files in a repo. Check them first, not last.

GitHub posture per repo:

```bash
gh repo list <org> --json name,visibility --limit 50
for r in <repos>; do
  gh api "repos/<org>/$r" --jq '{visibility, security_and_analysis}'
  gh api "repos/<org>/$r/branches/main/protection" --jq '{allow_force_pushes, allow_deletions}'
done
gh api "orgs/<org>" --jq '{two_factor_requirement_enabled, default_repository_permission}'
```

**Secret-scanning push protection is free on public repos and is the only control
that stops a credential before it lands.** Disabled on a public repo is High.
On private repos it needs GitHub Pro/Team — if unavailable, say so and record the
compensating controls (`.gitignore` coverage, placeholder-only hostnames) as an
accepted risk rather than an open finding.

### 2. BTP subaccount posture

```bash
btp --info                                        # which global account / API endpoint
btp list accounts/subaccount
btp list security/role-collection --subaccount <id>
btp list security/user --subaccount <id>
btp list services/instance --subaccount <id>
btp list services/binding --subaccount <id>
```

**Destinations are where the credentials live.** Export and review every one:

- `ProxyType=OnPremise` means it goes through the Cloud Connector — cross-check
  the resource actually exists in the SCC access control (Domain 3). A destination
  pointing at a resource that is *not* in the ACL fails closed; the reverse — an
  ACL entry with no destination — is an unused hole.
- `Authentication=BasicAuthentication` with `User`/`Password` properties stores a
  **shared technical user credential in the subaccount**. Every cloud user then
  acts as that one backend user: no attribution in the backend audit log, and the
  credential is readable by anyone with destination-editor rights. Prefer
  `PrincipalPropagation` (on-prem) or `OAuth2SAMLBearerAssertion`. Stored basic
  auth to production is **High**.
- `TrustAll=true` / `HTML5.DynamicDestination=true` — the first disables TLS
  verification, the second exposes the destination to browser-side apps.

Also check:

- **Service keys and bindings** are long-lived client secrets. Count them, find
  the oldest, and flag any that outlive the person who created them. `cf env <app>`
  and Kyma secrets both surface bound credentials in plaintext to anyone with
  space/namespace access — so space and namespace membership *is* credential access.
- **Trust configuration**: is the subaccount still on the default SAP ID Service,
  or on a corporate IdP/IAS? Default IdP for anything production-adjacent is a
  finding. Check whether "Available for user logon" is enabled on more IdPs than
  intended.
- **Role collections**: who holds `Subaccount Administrator`, `Cloud Connector
  Administrator`, and `Destination Administrator`. These three together are the
  keys to the on-prem tunnel.
- **Audit log retention.** The BTP audit log service has a short default retention
  (30 days on many plans). If nothing ships it to a SIEM, the effective
  investigation window is that number — record it.

For Kyma workloads (the DI auto-healer runs as one):

```bash
kubectl get secrets -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.type
kubectl auth can-i --list --namespace <ns>
kubectl get cronjob,deploy -A -o yaml | grep -nE 'image:|imagePullPolicy|runAsNonRoot|privileged|allowPrivilegeEscalation'
```

Flag: secrets created with `kubectl create secret --from-literal` in shell history,
containers running as root, `imagePullPolicy: Always` against a mutable `:latest`
tag, and any pod whose service account can read secrets cluster-wide.

### 3. Cloud Connector — the boundary

The highest-value domain. Everything here was verified against a real **2.19.1**
instance; see the `sap-cc-operations` skill for the API mechanics and the two
first-run 403 states.

```bash
# Read-only. Note the asymmetry: monitoring is NOT under /api/v1.
curl -sk -u "$SCC_USER:$SCC_PW" https://<host>:8443/api/v1/connector/version
curl -sk -u "$SCC_USER:$SCC_PW" https://<host>:8443/api/v1/configuration/subaccounts
curl -sk -u "$SCC_USER:$SCC_PW" https://<host>:8443/api/monitoring/subaccounts
```

Access control per subaccount is exposed under
`/api/v1/configuration/subaccounts/{subaccount}/systemMappings` and its
`.../resources` sub-path. **Probe rather than assume** — these are documented but
version-dependent, and the tooling's `--probe` mode reports what actually answered.
If the API is unavailable, read the configuration from the host instead; every
setting below is visible in `<scc-root>/config/`.

What to look for, in descending order of consequence:

| Check | Why it bites |
|---|---|
| **Resources with a `/` prefix and "path and all sub-paths"** | Exposes every service on that host. The single most common Critical. Each resource should be the narrowest path that works. |
| **`Access Policy` on each resource** | HTTP resources default to allowing sub-paths. RFC resources should name the function module or group, not `*`. |
| **Principal propagation vs stored credentials** | Without it, every cloud caller is one technical backend user — no attribution, and backend authorization checks are meaningless. |
| **Which subaccounts are connected** | An old dev subaccount still tunnelled into production is a live path nobody is watching. |
| **Admin UI (8443) network exposure** | Should be reachable from an admin network only. Internet-reachable is Critical. |
| **Administrator password changed from `manage`** | The shipped default. SAP publishes it. |
| **HA role set** | `undefined` means first-run state; it also makes half the config API return 403. |
| **The OS user running the JVM** | Should not be root. Check the process owner and the ownership of `config/`. |
| **`config/users.xml` permissions** | Holds the admin credential store. Must not be world-readable. |
| **Audit log level** | Should be at least "Security events". Off is High — this is the only record of who changed the ACL. |
| **Java patch level and SCC version** | An out-of-support SCC on an out-of-support JDK is the boundary component. |
| **Certificates in the UI's own keystore** | Expiry dates; a self-signed admin cert that everyone clicks through trains people to ignore TLS warnings. |

```bash
# On the SCC host, read-only
ps -o user,pid,cmd -C java | grep -i scc          # process owner — expect not root
ls -l <scc-root>/config/users.xml                 # expect 600, owned by the SCC user
ss -tlnp | grep -E ':8443|:443'                   # what is listening, and bound to what
```

### 4. NetWeaver — network exposure

The RFC Gateway and the ICF are the two ways into a NetWeaver system that people
forget they left open.

**Gateway ACLs.** Without `reginfo` and `secinfo`, any host that can reach the
gateway port can register an external server program and receive RFC calls.

| Parameter | Wanted | Meaning |
|---|---|---|
| `gw/reg_info` | set, file exists | Who may **register** an RFC server program |
| `gw/sec_info` | set, file exists | Who may **start** an external program |
| `gw/acl_mode` | `1` | Deny when no ACL matches (otherwise permissive) |
| `gw/reg_no_conn_info` | current recommended bitmask | Hardens registration handling |
| `gw/monitor` | `1` | Monitoring local only; `2` allows remote gateway admin |
| `gw/accept_remote_trace_level` | `0` | Stops remote trace-level changes |

Check via `SMGW` → Goto → Expert Functions → External Security (display), and
`RZ11` for each parameter. An empty ACL file is not the same as a missing one —
read the contents, and treat `P TP=* HOST=* ACCESS=*` as no ACL at all.

**Message server**: `ms/acl_info` set and populated; internal port
(`rdisp/msserv_internal`) not reachable from user networks. `SMMS` → Goto →
Expert Functions.

**ICF services** (`SICF`): the default set includes services that are rarely
needed and historically vulnerable. Walk active services and ask, per node, "does
a business process depend on this?" Pay attention to anything under `/sap/bc/`
that offers generic execution or introspection. Also confirm
`icf/set_HTTPonly_flag_on_cookies` is on and session cookies are `Secure`.

**ICM** (`SMICM`): which ports are open, HTTP vs HTTPS, and whether HTTP is
redirected. `icm/server_port_*` — an open plain-HTTP port carrying logon tickets
is High.

**SAProuter**, if present: read `saprouttab`. A trailing `P * * *` permits
everything and negates every line above it.

**Kernel and patch level**: `DISP+WORK` version, and whether the system is inside
SAP's maintenance window. Out-of-maintenance kernel on an internet-adjacent
system is High regardless of what else is right.

### 5. NetWeaver — identity and authorization

```
RSUSR003        default passwords for SAP*, DDIC, EARLYWATCH, TMSADM, SAPCPIC
                across ALL clients — including 000, 001, 066
RSUSR002        users by complex criteria (find SAP_ALL / SAP_NEW holders)
RSUSR008_009_NEW critical authorization combinations
RSPARAM         effective profile parameters vs defaults
```

**Default users are the classic Critical.** `RSUSR003` is the whole check and it
takes a minute. `SAP*` deserves special attention: if the user record is *deleted*
rather than locked, the kernel falls back to the hardcoded default unless
`login/no_automatic_user_sapstar = 1`. Verify the parameter, not just the user list.

**Password and logon policy** (`RZ11`, cross-check with `RSPARAM`):

| Parameter | Baseline |
|---|---|
| `login/min_password_lng` | ≥ 8, prefer 12+ |
| `login/password_expiration_time` | set, per policy |
| `login/fails_to_user_lock` | ≤ 5 |
| `login/failed_user_auto_unlock` | `0` (no auto-unlock) |
| `login/no_automatic_user_sapstar` | `1` |
| `login/password_compliance_to_current_policy` | `1` |
| `login/disable_multi_gui_login` | `1` in production |
| `rdisp/gui_auto_logout` | set |
| `auth/no_check_in_some_cases` | `Y` only if SU24 is actually maintained |
| `auth/rfc_authority_check` | `6` or current recommendation |
| `snc/enable` | `1` where SNC is deployed |

**Critical authorization objects.** Look for these on *dialog* users and on
widely-assigned roles, not just on emergency-access roles:

- `S_RFC` with `RFC_NAME = *` — the RFC equivalent of a wildcard
- `S_TABU_DIS` / `S_TABU_NAM` with broad table groups — direct table read
- `S_DEVELOP` in production — ABAP editor is code execution
- `S_ADMI_FCD`, `S_USER_GRP` (user administration), `S_PROGRAM`, `S_DATASET`
- `SAP_ALL` / `SAP_NEW` assigned to any named user in production is **Critical**;
  on a firefighter ID with logging and check-out it is Medium and worth naming
  as a compensating control

**RFC destinations** (`SM59`, and table `RFCDES`): every destination with a stored
user and password is a credential that survives password changes and is invisible
to the backend audit trail. Trusted RFC relationships (`SMT1`) form a graph — walk
it, because a low-tier system trusted by production is a path into production.
Flag destinations pointing *from* production *to* development.

**Client settings** (`SCC4`): production clients should be "not modifiable", with
cross-client customising and repository changes blocked. `T000` shows it directly.

**UCON**, if the release supports it: RFC function modules exposed externally
should be an allowlist, not "everything that exists".

### 6. Transport security and certificates

- **SNC** between SAP GUI and application servers, and on RFC. Without it, logon
  data and business payloads cross the network in the clear. `snc/enable`,
  `snc/data_protection/min`.
- **TLS** on ICM (`STRUST`): certificate expiry dates, key length, whether the
  chain is complete, and whether anything still trusts an internal CA that has
  been rotated.
- **Cloud Connector**: the tunnel to BTP is TLS on 443 outbound. Confirm no TLS
  interception proxy sits in the path unless deliberately architected — it
  terminates the tunnel and sees everything.
- **Certificate inventory with expiry** across STRUST, the SCC keystores, and any
  destination using client certificates. An expired cert on the tunnel is an
  outage, not a breach — but it lands at 3am.

### 7. Logging, audit trail and detection

A control nobody reads is a control that does not exist. For each of the four
audit trails, record **where it goes, how long it is kept, and who looks at it**:

| Trail | Where | Common gap |
|---|---|---|
| Security Audit Log | `RSAU_CONFIG` (7.50+) / `SM19`, read with `RSAU_READ_LOG` / `SM20` | Off, or on with filters so narrow they catch nothing. Must cover failed logons, RFC calls, user master changes, debug/replace |
| System log | `SM21` | Read only after an incident |
| Cloud Connector audit log | SCC UI → Audit, on the SCC host | Level "Off"; nothing ships it off the host |
| BTP audit log | Audit log viewer / service | Short default retention; not forwarded to a SIEM |

Also: table logging (`rec/client`) for customising tables, and whether change
documents are on for user and role administration.

Retention shorter than your realistic time-to-detect is itself the finding — say
so with the number.

### 8. The automation's own posture

Audit the tooling that touches these systems. It holds credentials and, in the
auto-healer's case, it *makes changes*.

- **Credential handling**: read from environment or a mounted secret, never from a
  config file in the repo. `password_env` naming an env var is the pattern; a
  `password` key with a value is the anti-pattern. Confirm passwords never reach
  logs, CSVs or raw-response dumps.
- **Write actions must be gated twice.** The auto-healer requires `mode: "live"`
  *and* `--execute`, plus the SID in `live_sids` — three independent gates, and
  `--offline` is rejected rather than ignored for live actions. Verify equivalent
  gates exist on anything new, and that the default is dry-run.
- **Attribution**: actions taken by automation should be traceable to a named
  technical account in the target system's own audit trail, not to a shared one.
- **Blast-radius limits**: `max_restarts_per_cycle`, `max_attempts_per_task`,
  cooldowns, storm thresholds, allow/deny lists. Confirm they exist, are enforced
  before the call rather than after, and are set to something a human agreed to.
- **The technical account's authorizations** should be the minimum: read for
  monitoring, plus exactly the one change right the automation needs. An automation
  account with `SAP_ALL` is Critical no matter how careful the code is.
- **Diagnostic output is customer data.** Trace logs, socket captures and API raw
  dumps carry hostnames, subaccount ids and system ids. They belong in `.gitignore`
  and must be scrubbed before going into a ticket or a report.

## Output: the audit report

Write to `docs/audits/YYYY-MM-DD-audit.md` — **outside any public repo**.

```markdown
# SAP Landscape Security Audit — YYYY-MM-DD

**Auditor**: Claude Code (<model>) via the `erplab5-security-audit` skill
**Scope**: Full / Targeted (<domains>)
**Systems audited**:
| Component | Version / SID | Environment | Evidence pinned at |
|---|---|---|---|
| BTP subaccount | <id> | prod / test | <date> |
| Cloud Connector | 2.19.1 | prod | GET /api/v1/connector/version |
| NetWeaver | <SID> kernel <patch> | prod | RSPARAM <date> |
| Repo <name> | `<sha>` (<subject>) | public / private / no remote | <date> |

## Summary

| Severity | Count |
|----------|-------|
| Critical |   N   |
| High     |   N   |
| Medium   |   N   |
| Low      |   N   |
| Info     |   N   |

**Top items requiring attention:**
1. ...

## Findings

### CRITICAL

#### C-1. <Title>
**Domain**: <1–8>
**System**: <SID / subaccount / repo> (<prod|test>)
**Evidence**: <transaction, API call, file:line, or command output>
```
<snippet>
```
**Impact**: <what an attacker or an accident does with this>
**Remediation**: <concrete, ordered steps>
**Compensating controls**: <what limits it today, if anything>

### HIGH / MEDIUM / LOW / INFO
...

## What was checked and found clean

- [x] ...

## Accepted risks

| Item | Why accepted | Compensating control | Review by |
|---|---|---|---|

## Carry-overs from previous audits

| Item | First flagged | Status |
|---|---|---|

## Recommended next audit
YYYY-MM-DD, or sooner if <trigger>.
```

The **accepted risks** table matters as much as the findings. A plan limitation
(no push protection on private repos without GitHub Pro) or a business constraint
is not a finding to re-raise every quarter — record it once, with the control that
substitutes for it and a date to revisit.

## Boundaries

- **Don't fix during the audit**, even one-liners. Read-only is what makes the
  result trustworthy.
- **Don't probe credentials.** One wrong guess against the SCC Administrator
  starts down the road to a locked account and an outage.
- **Don't read files that `.gitignore` deliberately excludes** to "check what's in
  them". Confirm they are ignored and untracked; ask the user to summarize
  contents if it matters.
- **No state-changing calls anywhere**: no `POST`/`PUT`/`DELETE` on SCC or BTP, no
  `btp assign`, no `cf set-env`, no `kubectl apply`, no ABAP in change mode, no
  `amplify push` equivalent.
- **Don't run the auto-healer with `--execute`** to see what it would do. That is
  what dry-run is for.
- **Production systems**: flag for review; do not propose changes to be applied
  directly. Stage remediation as a documented plan the user executes in a window.

## Related

- `sap-cc-operations` — the Cloud Connector API mechanics this audit reads:
  verified 2.19.1 paths, the two first-run 403 states, the trace format
- `sap-di-rms-api` — the DI RMS internal API, if replication flows are in scope
- `git-commit` — its never-commit guard is Domain 1's fast path at commit time;
  this skill is the periodic sweep that catches what the guard missed
- `dhc-security-audit` — the DigitalHome.Cloud equivalent for the Gatsby/Amplify
  platform. Same rubric and report shape; entirely different domains

## Prior audits

- 2026-08-14 — 0 critical / 1 high / 2 medium / 3 low / 4 info —
  `~/ERP-LAB-5/docs/audits/2026-08-14-audit.md`. Targeted (Domains 1 and 6 of the
  DHC skill, before this one existed): repo hygiene before first push. Nothing
  published; both remotes still at their creation commit. Top items: secret
  scanning and push protection disabled on the public `darkfactory` repo (H-1);
  a real DI preprod tenant id in `di-autohealer/config/config.json.demo` (M-1);
  no 2FA enforcement on the ERP-LAB-5 org (M-2).

When an audit completes, prepend a one-liner here with the date, counts and path.
