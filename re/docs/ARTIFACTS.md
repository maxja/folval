# Artifact layout — where evidence lives

Rules for every session. Machine-readable evidence is **JSONL only**; human-readable
text logs are the exception, never the rule.

| Path          | What belongs there                                                                 | Hygiene |
|---------------|------------------------------------------------------------------------------------|---------|
| `out/`        | Run-scoped probe evidence: `frida-run.sh` auto-tees every `send()`/log/error line as `<ts>-<target>-<probe>.jsonl`. Plus the `EVIDENCE.md` ledger and the `.keep` manifest. Gitignored — filenames/content may embed title identity. | `./lab.sh evidence:status` (dry-run) / `evidence:clean --force`. Keepers survive via `.keep`. |
| `logs/`       | Host daemon/process logs: `gateway.jsonl` (gateway events), `up.log`, `build.log`. | Cleanable any time the gateway is stopped. |
| `captures/pcap/` | Host tcpdump ring (`folval-*.pcapNN`). The oldest filename = coverage boundary — do not delete a ring a session still needs. | `evidence:clean` retires rings with no live base. Deploy dated bases via root `host/capture/install.sh`. |
| `tmp/`        | Guest-staging scratch (`.ps1`/`.cmd` one-offs) and gitignored third-party material (reference clone). One-off scripts **die here**; anything used in ≥2 sessions graduates to `host/tools/` (identity-screened first). | Delete freely once findings are distilled into `out/EVIDENCE.md` / `.ai-memory/misconceptions.md`. |
| `/tmp` (host) | **Nothing. Ever.** Volatile, outside the repo, survives no reboot. Patch scripts and section drafts go to project `tmp/` if they matter; heredocs if they don't. | `systemd-tmp` reaps it; treat as already deleted. |

## Why no console logs

`frida-run.sh` already tees every probe line (send/log/error) as JSON into
`out/`. Redirecting the runner's stdout to a side file (the old
`> /tmp/gpu-runNN.log` habit) duplicates the tee in a **weaker format**
(python-repr dicts, not JSON) and puts it outside the repo. If a console log
is ever genuinely needed (e.g. runner-level stderr), write it as
`out/<same-stem>.console.log` — never `/tmp`.

## Commit boundary

Everything under `out/`, `logs/`, `captures/`, `tmp/`, `.ai-memory/` is
gitignored. Committed docs (`re/docs/*`) carry distilled knowledge only and
must stay identity-free (see the identity policy in the handoff).
