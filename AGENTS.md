# Proxy maintenance

## Start here

Read [README.md](README.md) for the active Bash/Python/Go boundary. This was an incremental improvement, not a full CLI rewrite: Bash modules remain live compatibility features.

For code discovery, prefer codebase-memory-mcp (`search_graph`, `trace_path`, `get_code_snippet`, then `query_graph/search_code`). Index an unindexed checkout first. Use file searches for non-code/configuration or insufficient graph results. The local proxy graph project is `home-aruix-scripts-proxy`.

## Read by task

- **CLI, configuration, subscriptions, feedback, kernel management:** [automatic routing guide](docs/usage/adaptive-routing.md). Stateful management belongs in `libexec/`; preserve the public CLI and shell environment behavior when moving legacy logic.
- **Health, exits, logs:** [health guide](docs/usage/health.md).
- **Refactoring, menu/completion, uninstall, management CI:** [maintenance audit](docs/research/maintenance-audit.md) and linked open issue; legacy support is not evidence of full new-workflow integration.
- **Kernel selection, quality learning, persistence, upstream upgrades:** use the authoritative [mihomo fork](https://github.com/aruiplex/mihomo/tree/adaptive/stable). Locally its checkout is `$HOME/projects/mihomo`; follow its AGENTS.md and maintenance documentation when present. Use `adaptive/baseline.json`'s immutable upstream tag/commit for comparisons. `adaptive/base` has accepted patch merges and is not a pristine upstream baseline.
- **scripts integration or tickets:** in the parent checkout, read `docs/proxy-workflow.md` and `docs/agents/issue-tracker.md`. Proxy changes use `aruiplex/proxy`, cross-repository integration uses `aruiplex/scripts`. Update the parent's submodule pin separately and preserve unrelated local edits.

`prototypes/adaptive-routing/` is frozen prototype.2 evidence. Current kernel edits and freshly generated provenance belong in the fork.

## Runtime work

Before any operation that could change production, inspect current Git work, `proxy kernel status`, and the matching process supervisor afresh. Dated reports document past acceptance; they are not live state.

Keep ordinary tests in isolated roots, ports and service fixtures. For an authorized production cutover, prepare against current configuration, retain matching rollback snapshots, arm recovery outside the tool session, stop the matching main service before activating, then start through supervision. An ExecStopPost/deadline guard must recover if the task exits or acceptance fails.

After the startup command returns, use a separate invocation of `tests/integration/live_tls_acceptance.py` to verify real TLS/HTTP, continuous PID, owned listeners and the controller; include actual Codex use for application acceptance. Public probes alone are not authenticated AI evidence. Antigravity is deferred for this round; TCP acceptance does not cover TUN/UDP/QUIC.

Healthy streams stay open during feedback/failover; retry only establishment before business payload and never replay sent requests. Private subscriptions, controller secrets, quality history and raw traffic logs stay out of commits and shared reports.

## Validation and completion

Use meaningful checks for the changed behavior: Python management tests in `tests/unit/`, Bash syntax for edited shell files, and `tests/scripts-proxy.sh` in the parent for forwarding changes. Run isolated integration fixtures for the seam affected. Kernel acceptance uses the fork's pinned fixture checkout and report digests, not the current working tree by assumption.

Documentation-only changes need link/command consistency and diff checks; do not restart production or rerun the full kernel matrix for prose.

Before marking a change complete, distinguish implemented and tested behavior from deferred scope, record new maintenance gaps in the owning tracker, and report material validation limits.
