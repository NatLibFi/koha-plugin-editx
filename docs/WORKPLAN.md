# EDItX Development Workplan

This document captures the working plan after the May 2026 branch split. Treat it
as a coordination note, not as a substitute for reading the current code before
editing.

## Current Working Branch

The National Library of Finland working branch is:

```text
/Users/nugged/Dropbox/git/koha/plugins/koha-plugin-editx
branch: main
```

This branch contains the feature work that was built and tested for our
preproduction flow. The earlier plan was to port the finished work to
`ks-25.11`, but that target is obsolete.

The active KohaSuomi comparison branch is now:

```text
branch: ks25-v2
upstream: origin/ks25-v2
```

`ks25-v2` is a separate line of development and must be treated as an external
source for knowledge harvesting until we intentionally decide to merge, port, or
replace parts of it.

## Worktree Rules

Do not use stale Codex worktrees for new edits. In May 2026 these were observed
as prunable or detached:

```text
/private/tmp/editx-2511-main
/Users/nugged/.codex/worktrees/06cc/koha-plugin-editx
/Users/nugged/.codex/worktrees/b268/koha-plugin-editx
```

Use the Dropbox checkout on `main` for our work unless Nug explicitly chooses a
new worktree.

Do not stage local sample data unless Nug explicitly asks:

```text
real_samples/
map_productform_3AMK_110526.csv
```

## Step Discipline

Use small, isolated commits. Keep unrelated formatting and historical cleanup out
of functional fixes.

After each completed step:

1. Run focused tests for the changed behavior.
2. Run broader tests when shared behavior or import processing changed.
3. Build a fresh KPZ for web installation testing.
4. Keep the KPZ build result visible in the handoff.

## UI Architecture Principle

This plugin is a Koha staff tool. Default to boring, inspectable Koha UI:

- TT templates rendered by the plugin or Koha.
- Koha staff CSS classes and Bootstrap-compatible markup.
- DataTables only where a genuinely tabular list benefits from sorting,
  filtering, or pagination.
- Small named vanilla JavaScript functions for local interactions.
- POST/redirect/get flows where a server-rendered page is enough.

Do not add SPA or frontend framework UI unless Nug explicitly approves it for a
specific workflow.

Bundled Vue, React, axios, or similar frontend dependencies are not automatically
LLM-friendly. For LLM-assisted maintenance they often add noise: duplicated
client/server validation, async state, generated or minified files, larger KPZ
artifacts, extra security review, and a UI style that drifts away from Koha.

LLM-friendly means simple, local, and inspectable. It does not mean
framework-heavy.

## Current Position On KohaSuomi `ks25-v2`

`ks25-v2` contains work that may be useful, but it also introduces choices that
conflict with our current branch direction. It must be reviewed deeply before
adoption.

Known examples to verify from code, not from memory:

- OpenAPI endpoints and a Vue/axios admin surface.
- A shift toward `edifact_messages`.
- Additional test data and XML examples.
- Validator and order processor changes.
- Cron and process hardening.
- New assumptions about paths, logs, memcache, and permissions.
- Removal or replacement of plugin-owned tables.

The existence of a Vue/admin implementation in `ks25-v2` is not a reason to port
that UI style into `main`. Harvest business logic, data-format knowledge,
fixtures, validation rules, operational assumptions, and test coverage first.
Only then decide whether any UI structure is worth keeping.

## Knowledge Harvest From `ks25-v2`

Before merging or porting anything, review every `ks25-v2` commit from the
branch point against our `main` branch. Do not cherry-pick by commit title alone.

Harvest categories:

- Real EDItX XML examples and edge cases.
- Vendor, SAN, qualifier, and EDI account assumptions.
- `edifact_messages` usage and status transitions.
- Duplicate and idempotency handling.
- Barcode generation details.
- Branch, location, fund, itemtype, and Finna material type mapping.
- Validator behavior and error messages.
- Cron locking, process recovery, and retry behavior.
- Log path and operational diagnostics.
- Tests that encode real business rules.
- README or testing instructions that explain KohaSuomi procedures.

For each harvested item, record one of:

- Adopt into `main`.
- Adapt into our architecture.
- Reject with reason.
- Defer until KohaSuomi submission strategy is chosen.

## Known Risk Areas To Recheck

These were important in earlier work and must be rechecked against the current
branch before any merge strategy:

- Prepared SQL for all dynamic values.
- `vendor_edi_accounts` compatibility across Koha versions.
- Whether `aqbudgets_spend_log` is optional/custom or expected in the target
  KohaSuomi environment.
- `C4::Biblio::GetMarcFromKohaField` API compatibility.
- Idempotency across repeated imports.
- Runtime logging and staff-visible diagnostics.
- KPZ packaging and versioning.

## Strategic Plan

1. Keep `main` clean and buildable.
2. Document the branch split and UI principles in `main`.
3. Perform a read-only, commit-by-commit knowledge harvest from `ks25-v2`.
4. Pull useful EDItX business knowledge into `main` in small commits.
5. Finish a working plugin for our own preproduction and production needs.
6. Decide how to approach KohaSuomi: propose our improved plugin, port our
   changes onto their line, or maintain a parallel version if that is safer.

The preferred outcome is one maintainable Koha-native plugin. If KohaSuomi's
branch forces a different shape, choose that deliberately after the harvest,
not because generated framework code happened to exist.

## Next Immediate Work

The next technical step is a read-only, commit-by-commit review of `ks25-v2`.
The output should be a harvest matrix that lists each useful change, the exact
commit or file that introduced it, and the proposed action for `main`.
