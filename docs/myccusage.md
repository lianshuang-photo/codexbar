# MyCCusage Integration

This document supersedes the original `myccusage-mvp.md` (which lived on the
`codex/myccusage-mvp` branch). That MVP was scoped too narrowly: it tied the
menu bar UI to the `ccusage-cherry-collector` npm daemon, so users without the
collector saw nothing useful. The new design treats **local usage display** and
**community leaderboard upload** as two independent paths.

## Goal

Let CodexBar surface ccusage-style local usage data for the supported provider
set directly from on-disk session logs, with **no required npm install and no
extra macOS permission prompts**. The community leaderboard
(`ccusage-cherry-collector`) becomes an optional add-on for users who want to
share data, not a hard dependency.

When a provider has a coding plan (Claude, Codex), the menu bar continues to
show plan-remaining metrics. When a provider has no coding plan (OpenCode,
OpenClaw, Cherry Studio) or the user has no plan attached, the menu bar falls
back to "today's local ccusage tokens / cost" computed entirely on the user's
machine.

## Supported providers

The ccusage-aligned provider set is fixed at five:

| Provider | UsageProvider case | Local session log root | Plan support |
| --- | --- | --- | --- |
| Claude Code | `.claude` | `~/.claude/projects/**/*.jsonl` (+ `$CLAUDE_CONFIG_DIR`) | yes (OAuth/Web/CLI) |
| Codex | `.codex` | `~/.codex/sessions/**` | yes (managed/live accounts) |
| OpenCode | `.opencode` | TBD — verified during PR #3 | no |
| OpenClaw | `.openclaw` (new) | TBD — verified during PR #5 | no |
| Cherry Studio | `.cherryStudio` | TBD — verified during PR #4 | no |

`UsageProvider.openclaw` does not exist yet in `Sources/CodexBarCore/Providers/Providers.swift`
and is introduced in PR #5.

`Cursor` is **not** in this set, because it is not a ccusage agent. The previous
`visibleProviders` whitelist on `PreferencesProvidersPane` included Cursor by
mistake; that whitelist is replaced by the discovery rule below.

## Architecture

```
                ┌─────────────────────────────────────────┐
                │   Local jsonl / session files (per      │
                │   provider; user-owned, no permission   │
                │   prompts to read)                      │
                └────────────────┬────────────────────────┘
                                 │
                                 ▼
            ┌──────────────────────────────────────────┐
            │ LocalUsageScanner protocol               │
            │  - todayTotals() -> CCUsageDailyTotals   │
            │  - per-provider implementations          │
            └────────────────┬─────────────────────────┘
                             │
              ┌──────────────┴───────────────┐
              ▼                              ▼
    ┌───────────────────┐         ┌────────────────────────┐
    │ Menu card model   │         │ MyCCusageSyncRunner    │
    │ - plan if any     │         │ (optional, community   │
    │ - else local      │         │  leaderboard only)     │
    │   today usage     │         └────────────────────────┘
    └───────────────────┘
```

Key invariants:

- The scanner reads files only. No subprocesses, no daemons, no network. This
  is what keeps the "no extra permission prompt" property.
- `MyCCusageSyncRunner` keeps running for users who choose to upload to the
  community endpoint, but it is no longer in the menu bar render path.
- Co-existence with a separately-installed `ccusage-cherry-collector` daemon is
  explicitly supported: both can read the same on-disk session logs because
  reads are idempotent. The daemon will continue uploading on its own schedule;
  CodexBar's in-app sync action is a no-op for users who only want local view.

## Components

- **`LocalUsageScanner` (new, `CodexBarCore`)** — protocol with a per-provider
  implementation. Claude reuses the existing
  `Sources/CodexBarCore/Vendored/CostUsage/*` machinery; the other four
  providers grow new scanner files.
- **`CCUsageDailyTotals` (new)** — value type: `{ inputTokens, outputTokens,
  cacheReadTokens, cacheCreateTokens, costUSD, modelBreakdown }`. Shared
  between scanners and menu rendering.
- **`UsageStore` integration** — store gains a per-provider `localUsage` cache,
  updated lazily on menu open and on snapshot refresh. The existing snapshot
  refresh paths stay untouched for plan-based metrics.
- **`menuCardModel(for:)`** — branches: plan available → plan; else local
  `CCUsageDailyTotals`; else "no data yet".
- **`PreferencesProvidersPane.providers`** — drop the hard-coded
  `visibleProviders` whitelist. The list becomes "providers that the user has
  enabled" intersected with "providers we ship a `LocalUsageScanner` or full
  data source for". This keeps ghost-state from old user defaults out of the
  UI without silently dropping configured providers.
- **`MyCCusageSyncRunner`** — stays. Used only by the optional "Sync now" /
  "Enable community upload" path. Bugs in this runner (#2/#3/#5/#6/#10 from the
  review) are still in scope, but no menu render path depends on it after this
  redesign.
- **`MyCCusageStatsClient` / leaderboard** — kept as-is for users who opt in to
  community upload. Decoupled from the local-usage display path.

## Non-Goals

- **No** reimplementation of the community leaderboard server. The
  `/api/usage-stats` endpoint contract stays.
- **No** writes to `~/.claude`, `~/.codex`, etc. CodexBar only reads.
- **No** background daemon shipped inside the CodexBar app bundle. Users who
  want continuous community upload still install `ccusage-cherry-collector`
  themselves; we just stop pretending that is the only path.
- **No** Keychain migration of the collector API key in this round.
- **No** new macOS entitlements. If a change would require a new entitlement,
  it is out of scope for this work.

## Verification

- Unit tests per scanner (sample jsonl fixtures, golden totals).
- Characterization tests for the menu card model: plan-present vs plan-absent
  vs scanner-empty branches.
- `make check && swift test` green before each PR merges.
- Manual smoke: launch CodexBar with `ccusage-cherry-collector` uninstalled and
  confirm all five providers display today's local totals.

## Implementation roadmap

Each item is one PR, base = `main`, target = `main`. Items in the same group
are independent and can be parallelized across worktrees.

### Group A — foundation (serial)

| # | PR | Notes |
| --- | --- | --- |
| 0 | Update this design doc | (this PR) |
| 1 | Introduce `LocalUsageScanner` protocol + `CCUsageDailyTotals`; adapt existing Claude `CostUsageFetcher` to it | Must merge before Group B starts |

### Group B — per-provider scanners (parallel, 4 worktrees recommended)

| # | PR | Worktree hint |
| --- | --- | --- |
| 2 | Codex `LocalUsageScanner` impl + tests | `wt/codex-scanner` |
| 3 | OpenCode `LocalUsageScanner` impl + tests | `wt/opencode-scanner` |
| 4 | Cherry Studio `LocalUsageScanner` impl + tests | `wt/cherry-scanner` |
| 5 | Add `UsageProvider.openclaw` case + OpenClaw `LocalUsageScanner` impl + ProviderDescriptor + icon | `wt/openclaw` (slightly bigger than the others) |

### Group C — UI + plumbing (serial after Group B)

| # | PR | Notes |
| --- | --- | --- |
| 6 | Menu card model: plan → local fallback branch logic | Depends on at least one of Group B merged |
| 7 | Preferences Providers pane: drop `visibleProviders` whitelist, replace with capability-based discovery | Depends on all of Group B merged |
| 8 | `MyCCusageSyncRunner` becomes optional; community upload UI is its own opt-in setting | Independent of #6/#7 in code, but easier to land after them |

### Group D — leftover review fixes (parallelizable)

Carried over from the code review of the original MVP branch. Each is a small
independent PR.

| # | PR | Source |
| --- | --- | --- |
| 9 | `MyCCusageSyncRunner`: split stdout/stderr pipes, drain via `readabilityHandler`, `waitUntilExit` after `terminate` | review #2 |
| 10 | Move collector version probe off the main thread (utility queue, async) | review #3 |
| 11 | `MyCCusageConfigStore.load` must not write to disk; move legacy upgrade to caller | review #6 |
| 12 | `MyCCusageStatsClient.statsEndpointURL` tighten path matching | review #7 |
| 13 | Leaderboard polling backoff + minimum interval | review #8 |
| 14 | `MyCCusageSyncRunner` pm2 status: whitelist instead of `nil`-permits-all | review #10 |
| 15 | `MyCCusageLeaderboardSnapshot.displayName` precedence test coverage | review #11 |

Review items #1, #4, #5 from the original list are absorbed into Group C
because the new design changes those code paths fundamentally.

## Branch hygiene

- All PRs base on `origin/main` and target `main`.
- `codex/myccusage-mvp` is **archived**. No further commits land there. The
  fixes from review that survive (#9-#15 above) are reapplied on top of `main`
  as fresh commits, not cherry-picked from the old branch wholesale, so each
  PR stays single-purpose.
- Per-PR branches follow `feat/myccusage-<thing>` or `fix/myccusage-<thing>`.
