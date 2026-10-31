# Codex relaunch live evidence

Real Codex CLI 0.160.0, using the existing ChatGPT login in disposable settings, on a private tmux socket with a 120-column by 40-row terminal. All lifecycle operations used a marked lab home. The lab path contained a space.

| Scenario | Rendered instructions | Actual Codex prompt | Observable result |
| --- | ---: | ---: | --- |
| short-inline | 3,231 bytes | 3,264 bytes | Model-written JSON matched independently generated intent and checkpoint tokens; original instruction prefix preserved byte-for-byte. |
| oversized-relaunch | 150,541 bytes | 271 bytes | Model-written JSON matched independently generated intent and checkpoint tokens; original instruction prefix preserved byte-for-byte. |
| oversized-second-relaunch | 151,361 bytes | 271 bytes | Model-written JSON matched independently generated intent and checkpoint tokens; original instruction prefix preserved byte-for-byte. |

Real codex exec with the entire encoded launch brief (150575 bytes) was refused by Linux: errno=7 Argument list too long. The same brief succeeded through fm-control relaunch using its generated pointer.

The second oversized relaunch used a new latest token and Codex returned that token while retaining the original intent and both historical tokens. See live-results.json for expected and observed values and *-completed-terminal.txt for the actual Codex interactions.

The targeted tests/fm-control-relaunch.test.sh completed with exit 0. No linters, formatters, static analysis, or complete repository suite were run.

Cleanup confirmed: the disposable lab, its isolated Codex settings, and the private tmux socket directory were removed; the private server returned exit 0 on shutdown.
