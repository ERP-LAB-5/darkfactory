---
name: sap-cc-operations
description: Operate and diagnose the SAP Cloud Connector — read its admin REST API (the monitoring paths are NOT under /api/v1, which is the mistake worth avoiding), parse its trace log, stand up a throwaway local instance from the portable Linux build, and work through "No tunnel channels available" (NoChannelsAvailableException). Use for "cloud connector", "SCC tunnel", "NoChannelsAvailableException", "no tunnel channels", "scc_core.trc", "ljs_trace.log", "SCC admin API", "tunnel dropped", "backend RFC through the connector", or when reaching for the tools in sap-cc-operator/troubleshooter/.
---

# SAP Cloud Connector — operations

The Cloud Connector (SCC) is the on-premise agent that holds a pool of long-lived
outbound TLS connections — **tunnel channels** — to a BTP subaccount's
connectivity endpoint on port 443. All cloud→on-premise traffic is multiplexed
over them.

Everything below was verified against a real **2.19.1** instance. Where a fact is
version-dependent, that is called out — assume nothing carries backwards.

## The admin REST API

**Monitoring is not under `/api/v1`.** This asymmetry is the single most common
source of 404s against the Cloud Connector, and it is not documented anywhere
obvious — it was read out of the JAX-RS annotations in `webapps/ROOT.war`.

| Path | Returns |
| --- | --- |
| `/api/monitoring/subaccounts` | tunnel state per subaccount |
| `/api/monitoring/connections/backends` | open connections per backend |
| `/api/monitoring/performance/backends` | backend response times |
| `/api/monitoring/performance/topTimeConsumers` | slowest calls |
| `/api/v1/configuration/subaccounts` | configured subaccounts |
| `/api/v1/connector/version` | `{"version":"2.19.1"}` |

Auth is HTTP basic as an SCC **Administrator** account against
`https://<host>:8443`. Older versions may differ, so probe rather than assume;
`scc-remote-watch.py --probe` reports what actually answered.

**Repeated failed auth locks the Administrator account.** Recovery on a test box
is to stop the JVM and restore `config/users.xml` from the archive. Do not
brute-force credentials against a production connector.

### Two 403s that are not permission problems

Both are first-run states. The connector tells you which in the response body:

```json
{"type":"FORBIDDEN_REQUEST","message":"operation unavailable unless initial password is changed"}
{"type":"FORBIDDEN_REQUEST","message":"method is not allowed for connector running with HA role undefined"}
```

Fix, in order:

```bash
# 1. change the shipped password (once)
curl -sk -u Administrator:manage -X PUT -H 'Content-Type: application/json' \
  -d '{"oldPassword":"manage","newPassword":"<new>"}' \
  https://<host>:8443/api/v1/configuration/connector/authentication/basic

# 2. give the instance an HA role  (POST, not PUT; lowercase enum)
curl -sk -u Administrator:<new> -X POST -H 'Content-Type: application/json' \
  -d '"master"' https://<host>:8443/api/v1/configuration/connector/haRole
```

**Gotcha:** including a `"user"` field in the password-change body makes it a
**silent no-op** — HTTP 204 and nothing changes ("provided user name is equal to
name of current user"). Send only `oldPassword` and `newPassword`.

### Polling the API costs the connector

Every poll is served by the same JVM that carries the tunnel traffic. The
monitoring subsystem gathers stats synchronously and can be slow on a busy
system. **During a live incident, prefer reading kernel socket state over ssh** —
that does not touch the JVM at all. If you must poll, keep the interval at 5s or
above and use one keep-alive connection.

## The trace log

The file name depends on the version:

- **2.19.1** writes `log/scc_core.trc`
- **older releases** wrote `log/ljs_trace.log`

The format is identical and self-documented in the file's own header:

```
Entry format: Timestamp#Level#Logger name#Thread name#Connection ID#Message
```

Two parsing traps:

1. **Unused fields are space-padded, not empty** — a record with no connection id
   reads `#          #`. Strip before comparing.
2. **Records are multi-line.** A stack trace belongs to the record above it, and
   `NoChannelsAvailableException` appears on the line *after* the `#ERROR#`
   header. Match patterns against the whole record, not line by line.

`sap-cc-operator/troubleshooter/scclog.py` implements both correctly; import it
rather than re-writing a parser.

## "No tunnel channels available"

```
ERROR#com.sap.scc.protocol.rfc#RfcPool_1_Thread_28#0x832fb866#
      Unable to send response to cloud due to missing channel
com.sap.core.connectivity.spi.NoChannelsAvailableException: No tunnel channels available
    at com.sap.core.connectivity.tunnel.core.impl.context.AbstractTunnelBridge.write()
    at com.sap.scc.protocol.rfc.RfcProtocolProcessor.sendResponse()
    at com.sap.scc.protocol.rfc.RfcProtocolProcessor.returnError()
```

Read the stack before measuring anything:

- **It is on the response path.** A request had already arrived and been
  dispatched to the backend. The channel died *between* request and response —
  a mid-flight teardown, not a "cannot connect" problem.
- **The frame above is `returnError()`, not the success path.** The processor was
  already returning an error when the write failed. The tunnel loss is likely a
  *symptom*. Look for the ERROR immediately preceding it **on the same thread**.

**In the large majority of cases the channel count at error time is 0** — the
tunnel was down, not saturated. Confirm that rather than assume it.

| Cause | Signature in the data |
| --- | --- |
| Firewall/NAT/proxy idle timeout killing the long-lived tunnel | `tun_estab` drops to 0 periodically, then recovers; errors cluster in the dip |
| Network flap / MTU / TLS interception | Same dips, plus `tun_synsent` > 0 and rising `CLOSE_WAIT` |
| Backend RFC calls outliving the tunnel | `backend_estab` high and flat, `tun_sendq_max` climbing before the error |
| fd/thread exhaustion in the SCC JVM | `fds` approaching `fd_limit`, `rfcpool_threads` pinned at its ceiling |
| Genuine channel-count ceiling under load | Errors only at one specific non-zero `tun_estab` value |

### Order of work

1. **`scc-chain.py` first** — it needs only the log you already have, no capture
   and no reproduction. It reconstructs what was logged before each error.
2. **Read the gap.** A sub-50 ms median between the predecessor and the tunnel
   error means they are *one* event: a call failed and the error response could
   not be written back — fix the predecessor and this disappears. Seconds apart
   means two separate events; check whether the backend call was still running
   when the tunnel dropped.
3. **No same-thread predecessor** means nothing failed first: the tunnel vanished
   under an in-flight call. That points at the network path, not the backend.
4. **Only then capture.** `scc-watch.sh` (locally) or `scc-remote-watch.py`
   (over ssh) at 1 s, for a full reproduction cycle, then `scc-correlate.py`.

**One RFC request is handled by one `RfcPool_*` thread.** Records sharing a
connection id but on another thread are concurrent traffic, not the cause.
Connection ids are also **reused across reconnects** — compare the record span
per id against the time between first and last error before treating one id as
one connection.

### What socket counts cannot tell you

`ss`/`netstat` see TCP state, not SCC's internal channel bookkeeping. A socket
can be `ESTABLISHED` while SCC has already marked the channel unusable, so a
non-zero count at error time is **not** proof the pool had a channel. Resolve the
ambiguity with the transition timeline and by raising the trace level to `Debug`
for the connectivity/tunnel components across the reproduction window (SCC UI →
Log And Trace Files — then put it back).

Regular dips at a fixed interval — every 300 s, every 3600 s — are a
firewall/proxy idle timeout, near-conclusively. Get the intermediary's idle
timeout and compare. Lowering SCC's TCP keepalive below that timeout is the usual
fix when the two line up.

## A throwaway local instance

The portable Linux build needs no root, no systemd and no container:

```bash
# SapMachine 21 (what SAP certifies for 2.19; go.sh accepts 1.8, 17, 21, 25)
curl -sSLO https://github.com/SAP/SapMachine/releases/download/sapmachine-21.0.12/sapmachine-jdk-21.0.12_linux-x64_bin.tar.gz
tar xzf sapmachine-jdk-21.0.12_linux-x64_bin.tar.gz

mkdir -p sapcc && tar xzf sapcc-2.19.1-linux-x64.tar.gz -C sapcc
cd sapcc
JAVA_HOME=$PWD/../sapmachine-jdk-21.0.12 nohup ./go.sh > ../scc-console.log 2>&1 &
```

Then change the password and set the HA role as above. **`go.sh` restarts the JVM
on exit code 42**, so kill the `go.sh` wrapper first if you want it to stay down.
Uninstall is `rm -rf`.

**A test instance cannot reproduce the tunnel error.** With no connected BTP
subaccount there is no tunnel, so the channel count stays 0 and
`NoChannelsAvailableException` never fires. What it *does* validate is tooling
against the real trace format, the real API paths, JVM auto-detection and the
fd/thread counters. Reproducing the real failure needs a connected subaccount and
then breaking the network path (drop outbound 443 with a firewall rule mid-call).

The distribution tarball is ~119 MB, SAP-licensed, and deliberately **not** in
git — it exceeds GitHub's 100 MB per-file limit. Get it from the SAP Software
Center.

## Handling data off a customer connector

Trace logs and captures carry internal hostnames, subaccount ids, backend system
ids and account names. They are gitignored in `sap-cc-operator` for that reason.
Keep them out of commits, out of artifacts, and out of anything published — and
scrub hostnames before quoting log lines into a report or ticket.

## The tools

In `sap-cc-operator/troubleshooter/` — dependency-free (bash + `ss`/`awk`;
Python 3.6 stdlib), and self-contained, so `scp -r` the directory to the SCC host.

| Tool | Purpose |
| --- | --- |
| `configure.py` | Renders `scc.conf` from the template so the others need no repeated flags |
| `scc-chain.py` | Reconstructs what was logged before each error, per connection id / thread. **Log only — run this first.** |
| `scc-watch.sh` | Samples socket state on the SCC host once per second |
| `scc-remote-watch.py` | Drives that sampler over ssh, or polls the admin API |
| `scc-correlate.py` | Joins trace errors against the samples |
| `scclog.py` / `sccconf.py` | Shared trace parser and config loader |

Config discovery order: `--config` → `$SCC_CONF` → `./scc.conf` →
`~/.config/scc-troubleshooter/scc.conf`. Config values are **defaults only** —
a command-line flag always wins. Passwords are never stored: the config holds the
*name* of an env var (`password_env`), read at runtime.

Sampling cost, measured on a 355-process workstation: `ss -tanp` (with process
attribution) ~45 ms per tick, ~4–5% of one core at 1 s; `ss -tan` (cheap mode,
`-P`) ~12 ms, ~1%. The expensive part is the `-p` process mapping, which walks
`/proc/*/fd` for every process — so cost scales with process count, not with
tunnel traffic. Cheap mode classifies sockets by port alone, so on a shared host
the `:443` count may include sockets that are not SCC's.
