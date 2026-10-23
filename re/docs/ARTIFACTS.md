# Artifact layout — where evidence lives

Rules for every session. Machine-readable evidence is **JSONL only**; human-readable
text logs are the exception, never the rule.

| Path          | What belongs there                                                                 | Hygiene |
|---------------|------------------------------------------------------------------------------------|---------|
| `out/`        | Run-scoped probe evidence: `frida-run.sh` auto-tees every `send()`/log/error line as `<ts>-<target>-<probe>.jsonl`. Plus the `EVIDENCE.md` ledger and the `.keep` manifest. Gitignored — filenames/content may embed title identity. | `./lab.sh evidence:status` (dry-run) / `evidence:clean --force`. Keepers survive via `.keep`. |
| `logs/`       | Host daemon/process logs: `gateway.jsonl` (gateway events), `up.log`, `build.log`. | Cleanable any time the gateway is stopped. |
| `captures/pcap/` | Host tcpdump ring (`folval-*.pcapNN`). The oldest filename = coverage boundary — do not delete a ring a session still needs. | `evidence:clean` retires rings with no live base. Deploy dated bases via root `host/capture/install.sh`. |
| `tmp/`        | Gitignored working artifacts, organized (2026-10-23): `crash/` (minidump+exe+analysis tools), `d9/` (decrypted convos, keylogs, server logs), `gateway/` (account.json, re-server-key.pem, sslkeys-gw.log, certs — inputs `gateway:gameserver` reads), `evidence/` (screenshots, license text), plus the third-party reference clone (do not touch). One-off scripts **die here**; anything used in ≥2 sessions graduates to `host/tools/` (identity-screened first). | Delete freely once findings are distilled into `out/EVIDENCE.md` / `.ai-memory/misconceptions.md`. |
| `/tmp` (host) | **Nothing. Ever.** Volatile, outside the repo, survives no reboot. Patch scripts and section drafts go to project `tmp/` if they matter; heredocs if they don't. | `systemd-tmp` reaps it; treat as already deleted. |

## Why no console logs

`frida-run.sh` already tees every probe line (send/log/error) as JSON into
`out/`. Redirecting the runner's stdout to a side file (the old
`> /tmp/gpu-runNN.log` habit) duplicates the tee in a **weaker format**
(python-repr dicts, not JSON) and puts it outside the repo. If a console log
is ever genuinely needed (e.g. runner-level stderr), write it as
`out/<same-stem>.console.log` — never `/tmp`.

## Identifying & cleaning dated artifacts (runbook)

**Where dates live (naming grammar):**
- `out/` — `<YYYYMMDD>-<HHMMSS>-<target>-<probe>.jsonl`; the date prefix is the run
  moment. Keepers are whitelisted by exact filename in `out/.keep`.
- `captures/pcap/` — ring members share a **base**, the date-stamped filename root:
  `folval-YYYYMMDD-HHMMSS.pcapNN` (current unit) or legacy `folval.pcapNN`. The base's
  first-capture timestamp = when coverage started; the newest member's last packet =
  when coverage ended. **The base filename is the coverage boundary** — never rename.
- `logs/` — undated, append-per-run (`gateway.jsonl`). Treated as disposable.

**Liveness rule for pcap rings:** a base is **LIVE** only while a tcpdump process
holds it (`pgrep -af tcpdump` → `-w <file>`); everything else is STALE and safely
deletable *once its window is distilled*. Caveat: a containerized shell may not see
host processes (PID-namespace) — if `evidence:status` says "not visible", judge by
effect (`capinfos` last-packet time vs wall clock; a ring whose last packet predates
the running session cannot be the live one).

**Cleanup order (matters):**
1. **Distill first, delete second.** Raw evidence deleted before its findings land in
   `out/EVIDENCE.md` / `re/docs/PROGRESS.md` / `.ai-memory/misconceptions.md` is gone
   forever.
2. Stop the gateway (`./lab.sh gateway:stop`) — cleaning `logs/` while it runs
   unlinks an open fd: space is not freed and the ledger splits across inodes.
3. Curate `out/.keep` (add exact filenames worth keeping).
4. Dry-run: `./lab.sh evidence:status` — read the KEEP/STALE/CLEAN verdicts and ring
   coverage windows before agreeing with them.
5. `./lab.sh evidence:clean --force` — removes non-keepers in `out/`, empties
   `logs/`, retires STALE ring bases; LIVE bases and keepers are preserved.
6. Verify: `du -sh out/ logs/ captures/pcap/` and re-run `evidence:status`.

**Never clean:** `.keep`-listed files, `out/EVIDENCE.md`, a ring base whose coverage
window includes a session you haven't distilled yet, and anything under a running
process's cwd/fd (stop it first).

## Commit boundary

Everything under `out/`, `logs/`, `captures/`, `tmp/`, `.ai-memory/` is
gitignored. Committed docs (`re/docs/*`) carry distilled knowledge only and
must stay identity-free (see the identity policy in the handoff).
