---
name: sap-di-rms-api
description: Call the SAP Data Intelligence RMS (Replication Management Service) internal API — list replication flows, read task monitors and partition-level errors, and start, resume or suspend flows and individual tasks. The public DI API does not cover RMS at all; this is the unsupported internal API the Monitoring UI itself uses, so the endpoints, the tenant\\username basic-auth form and the x-requested-with header are all easy to get wrong. Use when working with replication flows, RMS task monitors, restarting or suspending DI tasks, scheduling RMS flows, or debugging 404s and 401s against /app/rms/api/dt/v1.
---

# SAP DI — RMS internal API

The **public** Data Intelligence API does not cover RMS. Everything below is the **internal,
unsupported** API that the DI Monitoring UI itself calls. It works and it is the only way to
automate replication flows, but SAP guarantees nothing across releases — re-verify after an
upgrade.

Verified on: a DI 3.x preprod tenant, ~125 replication flows, 2026-08-13/14, by reading
the Monitoring UI's `ReplicationService` and calling the endpoints directly. Cross-checks against
Ian Henry's SAP Community blog, *Scheduling RMS Flows in Data Intelligence via the Internal API*
(Nov 2022).

## Getting connected

```
Base:  https://vsystem.ingress.{tenant}.dhaas-live.shoot.live.k8s-hana.ondemand.com
Path:  /app/rms/api/dt/v1
Auth:  HTTP basic, user name as  <tenant>\<username>   e.g.  default\di-support
```

Two things account for nearly every failed first attempt:

- **The login is `tenant\username`.** A wrong tenant is rejected exactly like a wrong password,
  so check it first. Some configs store the whole string in one field — accept both forms rather
  than blindly prefixing, or you get `default\default\user`.
- **`x-requested-with: Fetch` is required on writes.** This *is* the CSRF mechanism; there is no
  `X-CSRF-Token` handshake and no token in the UI's traffic. Send it on every request.

A rejected login does not reliably return 401. vsystem may answer **200 with the HTML logon
page** after redirecting there, so check the content type or the final URL, not just the status.

## Reads

| Endpoint | Returns |
|---|---|
| `GET /replicationflows` | all flows: name, version, state, change info |
| `GET /replicationflows/{flow}` | detail: description, version, source/target spaces, tasks |
| `GET /replicationflows/{flow}/configuration` | priority, per-task priorities, spaces |
| `GET /replicationflows/{flow}/taskMonitors` | **the workhorse** — tasks, metrics, partitions |
| `GET /replicationflowMonitors[?name={flow}]` | monitor summary incl. `taskMetrics.error` |
| `GET /replicationflows/{flow}/changerequeststatus` | outcome of the last write on that flow |

There is **no bulk task-monitor endpoint**: `taskMonitors` is one call per flow. On a 125-flow
tenant a full sweep is 126 calls and takes several minutes. If you only need to know *which*
flows are unhealthy, `replicationflowMonitors` gives `taskMetrics.error` per flow far more
cheaply — but it stops at flow level and has no partition detail.

## Writes

One endpoint, four behaviours, chosen by query parameter:

```http
PUT /app/rms/api/dt/v1/replicationflows/{flow}?requestType={TYPE}
x-requested-with: Fetch
Content-Type: application/json

["taskName", ...]
```

| requestType | Effect | Body |
|---|---|---|
| `RUN_OR_RESUME_ALL_INACTIVE_TASKS` | start / resume the flow | none |
| `SUSPEND_ALL_ACTIVE_TASKS` | stop the flow | none |
| `RUN_OR_RESUME_SELECTIVE_INACTIVE_TASKS` | start / resume named tasks | `["task", …]` |
| `SUSPEND_SELECTIVE_ACTIVE_TASKS` | suspend named tasks | `["task", …]` |

Returns **202 Accepted** with `{"url": "/api/dt/v1/replicationflows/{flow}/changerequeststatus"}`.
The call is asynchronous: 202 means accepted, not done. Poll that URL for
`status: "COMPLETED"` and `requestCompletedAt`. It reports the flow's **last** change request by
anyone, so it cannot separate two requests issued close together.

There is **no `/restart` endpoint**, no `POST`, and nothing at `/tasks/{task}/…`. The design-time
API answers `Allow: GET, OPTIONS`; a guessed `/replicationflows/{flow}/tasks/{task}/restart` is a
404. Restarting is *resuming an inactive task*.

## Before you automate a restart

**"Inactive" is not the same as "broken".** `RUN_OR_RESUME_*_INACTIVE_TASKS` resumes anything not
currently running, which includes states you must not touch:

| Task state | Safe to resume? |
|---|---|
| `ERROR`, `active: false` | **yes** — parked because it broke |
| any `active: true` (`INITIAL_RUNNING`, `DELTA_RUNNING`, `RETRYING`) | no — nothing to resume, the call is a no-op |
| `CREATED` | no — never ran; you would start an initial load nobody asked for |
| `COMPLETED` | no — you would reload the data |
| `SUSPENDED` | no — a person stopped it; resuming overrules them |

Filter on `status == "ERROR" and active == false`. On a live tenant this cut 38 apparent restart
candidates to 12; the other 26 were `INITIAL_RUNNING` tasks whose individual partitions had
errors while the task itself kept running.

**Check `retryCount` before restarting.** DI retries by itself, relentlessly — median **502**,
maximum **5413** across tasks parked in `ERROR`. A task in `ERROR` has already exhausted DI's own
retry policy. Restarting is not the first attempt at recovery, and a task that failed 5413 times
will not be fixed by 5414.

**Watch for correlated failures.** A source-system outage looks like dozens of independent task
errors: on one cycle, 227 of 259 affected partitions failed inside four minutes across unrelated
flows, all reporting *"An exception was raised / System failure"*. Restarting each one hammers a
system that is already down. Cluster by error text and time before acting.

## Where errors actually live

Flow → task → partition. Error text is on the **partition**'s `statusInfo`, not the task's —
except when a task fails during setup, in which case it has **no partitions at all** and the
error is on the task's own `statusInfo`:

- *"Source setup failed … It is not possible to use the action \"Replication\" for object X"*
- *"Target setup failed … incompatible partfile metadata"*

A partition-only walk silently misses these. On one tenant that was 31 of 45 tasks in `ERROR`.

Useful task fields: `status`, `active`, `statusInfo`, `numberOfPartitions`, `lastRuntimeUpdated`,
and in `initialLoadMetrics` / `deltaLoadMetrics`: `retryCount`, `errorCount`, `lastErrorAt`,
`lastActivatedAt`, **`lastActivatedBy`**, `lastSuspendedAt/By`, `lastRetriedAt`, `activeCount`.

`lastActivatedBy` records the account that acted — both an audit trail and a free way to verify
your own call landed.

Partition fields: `transferMode` (`INITIAL` / `DELTA`), `status`, `statusInfo`,
`statusInfoTimestamp`, `retrying`, `additionalErrors`, `partitionMetrics`.

## Discovering more endpoints safely

The UI is the documentation. To find a call without triggering it:

1. Open the Monitoring UI, `/app/monitoring-ui/#/replications`.
2. Find the service module in the SystemJS registry — `monitoring/services/replicationService.js`
   exposes `getTaskMonitors`, `executeTasks`, `getConfig`, `setConfig`, `callApi`.
3. **Replace `callApi` on the prototype with a recorder that swallows writes**, then invoke the
   method or click the button. You get the exact URL, verb and body with nothing sent to DI.
4. Restore the original method afterwards.

This is how the `executeTasks` contract above was established without performing a single write.

## Known limitations

- No per-task undeploy. A configuration change (fields, filters) means undeploying and restarting
  every task in the flow.
- One RMS flow per connection, so one flow per task needs one connection per task.
- A flow that has completed may not restart cleanly; reported, unresolved.
- The DI scheduler cannot schedule a delta directly — the usual workaround is a Modeler pipeline
  with an `OPENAPI` connection calling these endpoints, scheduled as a graph.

## Related

- `~/DL5-Experimental/KONE/di-autohealer/docs/rms-api.md` — the same reference with the project's
  usage and response samples
- `~/DL5-Experimental/KONE/di-autohealer/` — a working client: `src/clients/di_http.py` (auth,
  CSRF header, logon-page detection), `di_monitor_client.py` (reads), `di_action_client.py`
  (the PUT), `src/healing_policy.py` (when a restart is actually the right answer)
