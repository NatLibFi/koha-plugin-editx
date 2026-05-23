# KohaSuomi `ks25-v2` Harvest

This document is the durable decision log for knowledge harvested from the
KohaSuomi `ks25-v2` line into our `main` line. Keep it updated when the local
`origin/ks25-v2` snapshot changes, when a harvested item is implemented in
`main`, or when Nug makes a new architecture decision.

## Verified Snapshot

- Main branch: `main`
- Main head at harvest: `800cba8` (`Document current EDItX lifecycle and config`)
- Comparison branch: local `origin/ks25-v2`
- Comparison head at harvest: `9793a7010c8d12c6d14a6d94f9493e86dbecf836`
  (`Drop separate plugin table`)
- Merge base: `2e48d606d9590caecc2a7226a6dc216d3e06ed59`
- Network refresh: not used; this is based on the local ref snapshot only.

`ks25-v2` is an external knowledge source, not a merge target. The current
`main` architecture remains the default unless Nug explicitly approves a
behavioral or architectural change.

## Main Direction

Keep these `main` choices unless a later decision explicitly changes them:

- Koha-native staff UI with TT templates, Koha staff classes, Bootstrap-compatible
  markup, and small vanilla JavaScript.
- Server-rendered flows and POST/redirect/GET where practical.
- Plugin `config_json` as the active configuration store.
- `SchemaLifecycle`, `ConfigMigration`, `RuntimeLog`, `ImportRunner`,
  `VendorEdiAccount`, SFTP sources, and folder sources as current architecture.
- Plugin-qualified lifecycle tables owned by the plugin.
- Upgrade-only migration from supported legacy schema and XML configuration.

Tests, fixtures, and validation knowledge are safe to harvest first. Queue
semantics, REST routes, Vue/admin UI, lifecycle changes, and deployment model
changes are behavior or architecture decisions and need separate approval.

## Harvest Matrix

| Commit/File | What it adds | Category | Recommendation | Reason / main impact |
| --- | --- | --- | --- | --- |
| `b5e139d` `Koha/Plugin/Fi/KohaSuomi/Editx/t/data/valid_shipnotice.xml`; `Koha/Plugin/Fi/KohaSuomi/Editx/t/send_xml.t` | Realistic LibraryShipNotice fixture shape with BTJ-style seller, SAN, fund, ProductForm, copy detail, and MARCXML message payload. | tests/fixtures, validation | Adopt now | Use as business knowledge, but rewrite as current `t/fixtures/*` and focused parser/validator tests instead of porting old test harness. |
| `1b16734` `Koha/Plugin/Fi/KohaSuomi/Editx/t/validator.t` | Validator scenarios for valid XML, invalid XML, missing BuyerParty NameLine, unknown seller, invalid SAN, missing/invalid fund, missing ProductForm, MessageType errors, and MessageType `01`. | validation, tests/fixtures | Adopt now, then expand | Current `main` already has focused validator tests for MessageType and copy locations. Add more isolated tests when the underlying validators can be exercised without fragile Koha DB setup. |
| `4618fcd`, `b42d9ad` `Koha/Plugin/Fi/KohaSuomi/Editx/t/orderprocessor.t` | Order processing assumptions around authoriser, allowed locations, branch/location/fund mapping, ProductForm, and error logging. | order processing, tests/fixtures | Adapt later | Useful business rules, but old tests depend on live Koha state, hardcoded schema paths, and broad mocks. Rebuild as smaller current-style tests. |
| `6a362a9` `Koha/Plugin/Fi/KohaSuomi/Editx/t/validator.t` | Vendor and EDI account validation assumptions: SAN `12345`, qualifier `91`, seller `BTJ Finland Oy`, BuyerAssignedID `FI-BTJ`. | vendor matching, validation | Adapt later | Preserve as vendor-matching knowledge, but implement through current `VendorEdiAccount` and bind-parameter SQL boundaries. |
| `998733b`, `0764ee4`, `cf21cbb` test docs and populate scripts | KohaSuomi test data assumptions for branch, location, borrower/authoriser, fund, and UI population. | tests/fixtures, docs/deployment | Adapt later | Useful setup knowledge, but the final scripts are not our test style and may mutate local Koha state too broadly. |
| `a01703f`, `3ddd7b7` `Procurement/OrderProcessor/Order.pm` | 024$a matching with indicator handling. | order processing | Already in main | Current `main` already contains the safer implementation and tests from later work. Do not re-port. |
| `1fbf0b5`, `eb211df` `Procurement/FinnaMaterialType.pm` | Finna/Daisy material type and 599$a handling. | order processing | Already in main | Current `main` already includes this knowledge. Recheck only if new fixtures expose a missed edge case. |
| `bac7672` barcode generation changes | `preyymmddts` barcode seed format. | barcode generation | Already in main | Current `main` keeps this behavior with a safer plugin-qualified sequence lifecycle. |
| `3045fc3`, `b31ee71` `Procurement/Validator.pm`; REST endpoint validation | Validator refactor and REST validation call sites. | validation, UI/API | Adapt selectively | Reuse validation rules, not REST coupling. Current `main` should keep validator code callable from import runner and Koha-native UI. |
| `9a369cd` `Procurement/EdiMessage.pm`, `cronjobs/process_edi_messages.pl`, `cronjobs/runEditXImport.pl`, `t/process_edi_messages.t` | Queue-oriented import flow based on Koha `edifact_messages`, status changes, and process script. | import runner / queue / edifact_messages | Adapt later | Good direction for idempotency and staff visibility, but it changes runtime behavior and overlaps current `ImportRunner`. Needs an explicit design pass. |
| `d7e65bb` `Procurement/EdiMessage.pm`, `cronjobs/process_edi_messages.pl`, `t/process_edi_messages.t` | Cross-cron hardening and atomic process claiming. | cron/ops, duplicate/idempotency | Adapt later | High-value operational idea. Port only after deciding how `ImportRunner`, source success actions, and `edifact_messages` should cooperate. |
| `4860778` `Procurement/File.pm` | File handling fixes around import/recovery. | source intake/filesystem/SFTP, cron/ops | Adapt later | Compare with current SFTP/folder sources and success actions before porting; do not bypass current source model. |
| `587c202` controller changes | ShipNoticeNumber extraction for queue/display paths. | duplicate/idempotency, UI/API | Adapt later | Useful duplicate key candidate, but behavior must be defined against current file import and basket creation rules. |
| `4d6d93f`, `78cf0c2`, `1807601` `Controllers/EditxController.pm`, `openapi.yaml`, `admin_editx.tt`, `js/app.js` | REST endpoints, OpenAPI, admin page, pagination, and controller wiring. | UI/API | Defer / architecture review | Keep as reference for workflow concepts only. Do not replace Koha-native TT flows or current static API without approval. |
| `f0ed0c7` bundled Vue and axios assets | Local frontend framework dependencies. | UI/API, packaging/release | Reject | Conflicts with Koha-native UI direction, increases KPZ size and review surface, and would add a second client-side app model. |
| `998ca97`, `c07e28e`, `3a64e92`, `07cf2fb`, `9793a70` lifecycle changes | Unqualified `map_productform`, `sequences`, plugin data barcode seed, plugin-owned `aqbudgets_spend_log`, and dropped plugin table. | lifecycle/schema | Reject direct port | Conflicts with current `SchemaLifecycle`: install only current plugin-qualified tables; upgrade handles legacy copy; `aqbudgets_spend_log` is optional KohaSuomi integration, not plugin-owned lifecycle. |
| `dd1f44d`, `92d7d35`, `46febfa` config changes | UI settings moved toward plugin config and path assumptions reduced. | config/config migration | Mostly superseded by main | Current `main` already uses `config_json`, `ConfigMigration`, and source config. Recheck only for missed setting names or validation copy. |
| `4522479` config fallback | Runtime fallback to legacy config fetching. | config/config migration | Reject | Current `main` intentionally migrates legacy XML once during upgrade and then removes runtime XML fallback. |
| `d9c4a51`..`b4e7fc8` GitHub test workflow changes | Perl test workflow, memcache, directory permissions, path replacement, verbose test mode. | cron/ops, docs/deployment, packaging/release | Adapt later | Valuable CI and deployment knowledge, but must be rewritten for our current test layout and packaging assumptions. |
| `origin/ks25-v2:README.md`; `Koha/Plugin/Fi/KohaSuomi/Editx/t/README.md`; `Koha/Plugin/Fi/KohaSuomi/Editx/t/TESTING.md` | Operational notes and test setup. | docs/deployment | Defer / verify as stale | Some names, paths, and table assumptions contradict current `main`; treat as clues, not source of truth. |
| `.github/workflows/release.yml`, `deploy.sh` in `ks25-v2` | Release/deploy automation. | packaging/release | Reject as-is | Contains branch/path assumptions and potentially destructive deployment mechanics. Current release packaging should stay explicit and reviewed. |

## Adopt Now

Adopt these immediately because they add business knowledge without forcing a
runtime architecture decision:

- A current-style BTJ LibraryShipNotice fixture derived from `b5e139d` and later
  order processor examples.
- Parser assertions for SAN, seller account identifiers, ProductForm, ISBN/EAN,
  pricing, copy detail, fund, branch/location-style routing fields, and
  MessageType.
- MessageType `01` fixture knowledge: informational message content must not be
  forced through MARCXML validation.
- Focused tests that keep fixture meaning visible and do not require broad Koha
  DB state unless the behavior being tested genuinely needs it.

## Adapt Later

These are useful but need a design pass before implementation:

- `edifact_messages` queue integration, status transitions, and staff visibility.
- Atomic claiming and cross-cron recovery from `d7e65bb`.
- Duplicate detection based on ShipNoticeNumber and/or message ledger state.
- Vendor/SAN/qualifier diagnostics around `VendorEdiAccount`.
- Branch/location/fund/itemtype/Finna mapping coverage using isolated builders or
  narrow mocks.
- CI workflow improvements for memcache, directory permissions, and verbose test
  output.

## Reject

Do not port these into `main` without a new explicit decision:

- Direct replacement of current lifecycle modules or plugin-qualified tables with
  unqualified KohaSuomi-local tables.
- Plugin-owned creation of `aqbudgets_spend_log`.
- Runtime fallback to legacy XML or `plugin_data` config after migration.
- Hardcoded plugin paths such as `/var/lib/koha/plugins/.../XmlSchema/`.
- Shell XML validation where `XML::LibXML` can be used directly.
- SQL interpolation for dynamic values where bind parameters are required.
- Vue/axios/admin SPA as the default staff workflow.
- Bundled frontend framework assets as default packaging.
- Stale release/deploy scripts with local path or branch assumptions.

## Stale Documentation To Recheck

The following `ks25-v2` docs are useful context but are not authoritative for
our `main` line:

- `origin/ks25-v2:README.md`
- `origin/ks25-v2:Koha/Plugin/Fi/KohaSuomi/Editx/t/README.md`
- `origin/ks25-v2:Koha/Plugin/Fi/KohaSuomi/Editx/t/TESTING.md`
- `origin/ks25-v2:.github/workflows/release.yml`
- `origin/ks25-v2:deploy.sh`

When these contradict current code, `docs/WORKPLAN.md`, or this harvest file,
treat them as stale until verified against a real deployment need.

## Next Isolated Commit Order

1. Add harvested fixtures and current-style parser/validator tests.
2. Add any missing focused validator tests that can run without fragile Koha DB
   state.
3. Design `edifact_messages` integration against current `ImportRunner`,
   source success actions, runtime logging, and Koha-native staff UI.
4. Add duplicate/idempotency tests before changing import behavior.
5. Adapt cron hardening and recovery once the queue/import design is approved.
