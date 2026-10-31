Codex regular-service live validation

Installed CLI: codex-cli 0.160.0.

Two real batch workers and one real scout were launched by bin/fm-spawn.sh through real Treehouse leases into a private tmux server. All three had 120x40 terminals and the fixed service_tier="default" argument in their running Codex process. Persisted task metadata contained no configurable service tier. The lab and its private tmux server were removed after capture.

The real Codex app-server config/read API resolved those observed process flags against a temporary Fast configuration. All three resolved to default; removing only the service-tier override resolved to fast. The actual features interface reported hooks disabled for workers.

Secondmate launch construction used the repository's mock-transport fixture. Its generated flags were then passed to the real Codex app-server and features interfaces: service tier default, hooks enabled. This is live configuration evidence, not a claim of a live secondmate lifecycle.

The worker TUIs reached the folder-trust prompt. It was left unanswered to preserve user-level trust configuration. No model response or provider billing tier was asserted. This change affects CLI configuration, not visual layout; process arguments and API responses are the primary product evidence.

Validation command completed successfully: bash bin/fm-test-run.sh --jobs 1 tests/fm-codex-hook-layer-live-e2e.test.sh tests/fm-spawn-dispatch-profile.test.sh. No source changes were made.
