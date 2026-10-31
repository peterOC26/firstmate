# Codex regular-service live validation

Installed product: `codex-cli 0.160.0`.

The evidence driver ran the current `bin/fm-spawn.sh` against real tmux and Treehouse, with marked disposable lab homes and a private `fm-lab` socket. Every Codex terminal had a 140 × 45 grid before the TUI started.

| User action | Observed result |
| --- | --- |
| Start a Codex-only batch with two workers | Both native Codex processes received `-c service_tier="default"`. |
| Start a Codex second mate | The native Codex process received the same fixed pin. |
| Start with an existing Fast preference | Real Codex app-server `config/read` returned `fast` without launch flags, and `default` for the exact flags captured from each of the three running processes. |
| Inspect the resulting task records | All three recorded Codex as their tool and contained no saved `service_tier` setting. |

The TUI reached its folder-trust prompt. Trust was not approved, user configuration was not edited, and no model turn was submitted. The measured outcome is process launch and effective CLI configuration, not API billing or response speed. The temporary configuration home used by the config/read probes held no credentials and required no login.

Driver: `bash live-launch.sh` from the gate worktree. Driver setup errors (process selection and batch syntax) and read-only hook-directory cleanup were corrected, then the complete proof was re-driven successfully. `live-effective-config.json` and `live-metadata-check.json` contain the final observations; `live-process-argv.json`, the spawn logs, and pane captures retain their provenance. The private terminal server, lab homes, and task launch directories were removed afterward.
