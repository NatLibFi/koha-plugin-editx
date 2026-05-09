# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Added Koha plugin-qualified table setup for EDItX runtime data.
- Added explicit `Koha::DateUtils::dt_from_string` import in the plugin package.
- Added plugin web configuration for nightly EDItX synchronization.
- Added plugin web configuration for SFTP sources as YAML, including generic multi-source examples.
- Added plugin web configuration for import folders, processing rules, notification addresses, and ProductForm mappings.
- Added CSV ProductForm mapping editor with Koha item type validation and visible item type reference list.
- Added visible Koha branch and LOC reference lists to the processing rules section.
- Added Koha plugin `cronjob_nightly` hook for the nightly SFTP download plus import chain.
- Added shared `Procurement::ImportRunner` for the EDItX import chain: staging, parsing, validation, transactional order processing, archiving, duplicate skipping, and failure accounting.
- Added runtime log support with configurable levels: `off`, `error`, `warn`, `info`, `notice`, and `debug`.
- Added runtime log tail display to the plugin configuration page.
- Added runtime log integration for the existing procurement logger.
- Added a staff tool page for manual EDItX operations.
- Added manual `Download and import now` operation to the tool page.
- Added manual run result summary with acquisition basket/vendor/order/item links.
- Added staged manual workflow to the tool page: check remote SFTP files, download selected EDItX files for preview, and import selected staged files.
- Added downloaded EDItX preview with generic shipment notice metadata, vendor lookup status, duplicate status, item/copy counts, product forms, currencies, and estimated totals.
- Added read-only nightly automation status to the tool page, with a link to plugin configuration.
- Added Koha-instance based recommended import folder defaults for plugin configuration.
- Added LibraryShipNotice business contract fixture for validating parsed shipment notice structure.
- Added focused regression tests for tool/config page separation, breadcrumb behavior, config parsing, import runner behavior, file moves, XML parsing, SQL binding, vendor mapping, MessageType validation, and CopyDetail location validation.

### Changed
- Migrated runtime table usage from unqualified/legacy tables to Koha plugin-qualified table names.
- Made legacy `sequences` and `map_productform` migration idempotent during install/upgrade.
- Removed hard dependency on ProductForm mapping foreign keys to `itemtypes`.
- Made `productform` and `productform_alternative` nullable in the mapping table.
- Changed ProductForm mapping validation so unknown Koha item types are stored as empty values and reported to staff before save.
- Moved procurement settings toward plugin `plugin_data`, while retaining XML configuration fallback.
- Changed the plugin default method URL to open the tool page instead of the configuration page.
- Split operational actions from long-lived settings: manual download/import now belongs to the tool page, while configuration remains settings-only.
- Kept full manual download/import as a shortcut while making the staged workflow the safer pilot path for staff.
- Hid startup-only tool page actions while a staged manual workflow is active, keeping the current stage's next action prominent.
- Reworked breadcrumbs to follow the DB Toolbox pattern: plugin root points to the tool page and the configure shortcut is contextual.
- Reworked the configuration page styling toward the DB Toolbox layout with page header, status cards, Bootstrap wrapper, and full Koha breadcrumbs.
- Moved runtime logging to the bottom of the configuration page.
- Made the runtime logging configuration section collapsed by default and persisted with browser `localStorage`.
- Reduced the CSV mapping editor height to keep the configuration page scannable.
- Replaced customer-specific SFTP examples with neutral library examples.
- Kept SFTP examples out of saved defaults; fresh installs now start with an empty `sources: []` YAML value.
- Clarified import folder guidance on the configuration page, including the recommended Koha-instance EDItX data layout.
- Grouped SFTP readiness warnings on the tool page so staff see configuration blockers before running manual operations.
- Converted the legacy `runEditXImport.pl` cron script into a thin wrapper around the shared import runner.
- Removed shell-based XML validation from the EDItX validator and kept XML parsing in Perl.
- Deduplicated MessageType validation flow so the same missing/wrong MessageType is not reported through repeated branches.
- Validated CopyDetail destination locations together so multi-copy notices report the full location problem consistently.

### Fixed
- Fixed local Perl syntax checks by avoiding empty `-I` arguments and adding Koha source path guesses to the local builder.
- Fixed Koha template `filter not found` failures on the tool page by loading the `raw` Template Toolkit plugin.
- Fixed manual run UI placement so staff are not offered operational actions from the configuration page.
- Fixed manual run feedback so staff can open created acquisition baskets/orders directly after import.
- Fixed manual run fallback navigation so empty result summaries link to an acquisition order search for the run date instead of the general acquisitions home page.
- Fixed cron/manual import context so Koha background jobs get a valid `userenv` from the configured EDItX authoriser.
- Fixed manual run diagnostics so long captured output preserves both the beginning and end instead of hiding the final root cause.
- Fixed configuration save validation for import folders: unsafe relative paths, parent-directory segments, and non-directory parents now block save.
- Fixed console import configuration so cron/manual import scripts use the same Koha-instance import folder defaults as the web configuration page.
- Fixed import startup so configured EDItX tmp/load/archive/fail folders are created before file staging.
- Fixed manual run availability so the tool page blocks download/import when no usable SFTP source is saved.
- Fixed SFTP download diagnostics so SSH/host-key/key-permission errors are no longer hidden by quiet mode.
- Fixed XML parser schema lookup so plugin installs under instance-specific paths do not use a hardcoded global plugin directory.
- Fixed import runner handling of false order-processor results so they roll back and move the file to the failed folder instead of being treated as successful imports.
- Fixed import transaction handling to use Koha DBIx::Class transactions instead of raw DBI `begin_work`, avoiding nested transaction failures from Koha objects.
- Fixed the console import wrapper so failed EDItX files return a non-zero exit status to manual web runs and cron.
- Fixed console import diagnostics so failed EDItX file paths and root errors are printed to captured manual-run output.
- Fixed order processing return values so successful processing returns success and notices with no orderable copy details fail loudly.
- Fixed acquisition order creation diagnostics for missing budget mappings, missing order rows, invalid barcode prefix YAML, missing biblio metadata, and failed budget spend log writes.
- Fixed barcode generation so missing/blank `BarcodePrefix` falls back to `HANK_`, while a scalar value is accepted as a global default prefix.
- Fixed barcode MARC field lookups to use the modern `GetMarcFromKohaField` API when available, with a legacy fallback for older Koha versions.
- Fixed ISBN automatch so all ISBN candidates are searched instead of only the first argument.
- Fixed EDI message add/update/vendor-link operations so failed database writes die with context instead of being ignored.
- Fixed EDItX validation failures so they die with a usable message instead of an empty exception.
- Fixed XML object creation diagnostics when no EDItX object class can be determined from a parsed XML file.
- Fixed XML parser flow so a non-filtered file that cannot become an EDItX order object fails the import with an explicit message.
- Fixed seller-specific EDItX object detection so `Booky`, `BTJ`, and `Kirjavalitys` checks run on object instances instead of package-name strings.
- Fixed EDItX staging moves so failed moves die loudly instead of being logged as successful processing.
- Fixed archive/fail-folder import runner handling so failed file moves are logged without hiding the original import error.
- Fixed EDI message SQL handling by binding vendor lookup and update values.
- Fixed missing EDItX vendor mapping diagnostics so the failing SAN and qualifier are reported.
- Fixed EDI vendor lookup so it works with Koha schemas that do not have `vendor_edi_accounts.transport` or `orders_enabled` columns.
- Fixed EDI vendor lookup compatibility across legacy `vendor_edi_accounts.transport='FILE'` and newer `file_transports.transport='local'` schemas.
- Fixed EDI vendor lookup so a single active SAN/qualifier account is accepted even when newer Koha `file_transport_id` is not linked, while multiple active matches still fail as ambiguous.
- Fixed EDI vendor lookup safety so ambiguous accounts, disabled orders, qualifier mismatches, missing identifiers, and blank vendor ids fail with explicit staff-readable diagnostics.
- Fixed ProductForm install behavior by dropping old KohaSuomi seed mappings from legacy SQL setup.
- Fixed staged remote-file checking so web SFTP operations use Koha-packaged `Net::SFTP::Foreign` directly, list structured remote entries, filter filenames locally by the configured pattern, and show the SFTP operation plus empty listing details to staff instead of passing silently.
- Fixed staged selected-file import so the direct web runner does not echo console progress lines into the HTTP response before Koha renders the tool page.
- Fixed staged workflow run id handling so File::Temp-generated ids with underscores are valid, stale staged import forms return a staff warning instead of a 500 error, and download/import POSTs redirect to reload-safe GET pages.
- Fixed nightly cron import result reporting so duplicate files skipped during tmp-to-load staging are included in the final `skipped` count.

### Tested
- `prove -l t/*.t`
- `./local_build.sh`

## Planned next steps
### Phase 1 - Shared operational runner
- Extract the staged SFTP list/download/import code out of the plugin controller into shared package classes, so web tool runs, nightly cron runs, and diagnostics use one backend path.
- Keep the current shell fetch script as a compatibility wrapper until preproduction proves the plugin-owned staged flow.

### Phase 2 - Tool page refinements
- Add optional SFTP connection testing as a separate action before remote file listing.
- Add clearer local staged-file retention and cleanup behavior after import.
- Keep the current full download/import shortcut while the staged workflow is used for pilot operations.

### Phase 3 - Cron compatibility
- Wire `cronjob_nightly` to the same operational reporting model as the manual tool run.
- Keep backward-compatible console entrypoints until preproduction and production cron paths are fully migrated.
- Make plugin-owned nightly flow the preferred production path after SFTP delivery and import result links are verified.

### Phase 4 - Runtime logging pass
- Add meaningful `debug`, `info`, `notice`, `warn`, and `error` events across SFTP, file moves, XML parsing, validation, basket creation, order creation, and failures.
- Keep existing Koha warnings where useful, but make the plugin runtime log the staff-facing operational log.

### Phase 5 - Test expansion
- Add tests for SFTP connection test/list/download actions after they move into shared Perl code.
- Add tests for cron wrapper behavior and nightly result logging.
- Add integration-style tests for manual tool result rendering when Koha acquisition objects are available.

### Phase 6 - Legacy SQL cleanup
- Review `installation/create_tables.sql` now that ProductForm mappings are managed through the web configuration.
- Either align legacy seed data with the new nullable mapping model or document it as a manual/legacy setup artifact.

## [2.0.0] - 2024-03-04
### Added
- Added this changelog.
- And made first release on GitHub actions/releases version.

### Changed
- No changes in this release.

### Removed
- No removals in this release.
