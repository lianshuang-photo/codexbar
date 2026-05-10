# MyCCusage MVP

## Goal

CodexBar should surface and control the existing MyCCusage collector without duplicating collector configuration or reimplementing local usage scanners in Swift.

## Scope

- Read and write `~/.ccusage-collector/config.json`.
- Keep the API key in that JSON for this first version.
- Expose MyCCusage settings in the General automation area:
  - enabled state
  - endpoint
  - display name
  - agent type checkboxes for Claude Code, Cherry Studio, OpenCode, Codex, and OpenClaw
  - upload frequency
  - last upload, next upload, and last error status
- Add a `Sync MyCCusage Now` menu action.
- Implement manual and scheduled uploads by running `ccusage-cherry-collector sync`.
- Do not run `ccusage-cherry-collector test`; it is not treated as a dry run.
- Require `ccusage-cherry-collector` version `1.0.4` or newer for sync.
  If the binary is missing or older, CodexBar shows an install/upgrade command instead of running old collector logic.
- Read leaderboard data from the collector endpoint's `/api/usage-stats` route.
- Compute today's total tokens/cost, the current device rank, leader, and gap locally.
- Add a plain menu text row such as:
  `Community: #7 today $34.38 / 43.5M - leader jd $556.51 - gap $522.13`

## Non-Goals

- No LaunchAgent, PM2, or daemon management. Scheduled uploads only run while CodexBar is open.
- No new server endpoint is required for MVP.
- No custom animated menu row. The first version uses existing menu descriptor text/action entries.
- No migration of the API key to Keychain.
- No Swift reimplementation of Claude, Codex, Cherry Studio, or OpenCode collection logic.

## Components

- `MyCCusageConfigStore` in `CodexBarCore` owns JSON load/save and preserves unknown fields where possible.
- `MyCCusageStatsClient` fetches `/api/usage-stats` by deriving it from the configured `/api/usage-sync` endpoint.
- `MyCCusageLeaderboardSnapshot` parses stats payloads and computes the menu summary.
- `MyCCusageSyncRunner` locates and runs `ccusage-cherry-collector sync`.
  It also reads `ccusage-cherry-collector --version` and reports whether the installed collector satisfies the minimum version.
- `UsageStore+MyCCusage` owns observable runtime state, scheduled sync, manual sync, and stats refresh.
- `GeneralPane` renders settings and status.
- `MenuDescriptor` adds the community summary row and manual sync action.

## Verification

- Unit tests cover config read/write, agent type mapping, stats endpoint derivation, leaderboard ranking, sync command construction, and menu text.
- Focused tests run after each implementation step.
- Final verification runs `make check` and `swift test`.
