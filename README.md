# Koha-Suomi plugin Editx
Adds EDItX import support for Koha

# Development coordination
Current branch strategy, LLM-friendly UI guidance, and the KohaSuomi `ks25-v2` knowledge-harvest plan are tracked in [docs/WORKPLAN.md](docs/WORKPLAN.md).

# Downloading
From the release page you can download the latest \*.kpz file
# Installing
Koha's Plugin System allows for you to add additional tools and reports to Koha that are specific to your library. Plugins are installed by uploading KPZ ( Koha Plugin Zip ) packages. A KPZ file is just a zip file containing the perl files, template files, and any other files necessary to make the plugin work.
The plugin system needs to be turned on by a system administrator.
To set up the Koha plugin system you must first make some changes to your install.
    Change <enable_plugins>0<enable_plugins> to <enable_plugins>1</enable_plugins> in your koha-conf.xml file
    Confirm that the path to <pluginsdir> exists, is correct, and is writable by the web server
    Remember to allow access to plugin directory from Apache
    <Directory <pluginsdir>>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
    Restart your webserver
Once set up is complete you will need to alter your UseKohaPlugins system preference. On the Tools page you will see the Tools Plugins and on the Reports page you will see the Reports Plugins.
# Configuring

Install the KPZ and configure the plugin from the Koha staff interface. The configuration page stores EDItX settings in Koha `plugin_data` as the plugin-owned `config_json` value.

New installs should use the web configuration page. During plugin upgrade, a legacy `/etc/koha/sites/<instance>/procurement-config.xml` file is migrated into `config_json` when no saved plugin configuration exists yet. After a successful migration the XML file is moved aside so this plugin version cannot keep reading stale deployment-managed configuration.

## Nightly EDItX synchronization

The plugin importer reads incoming EDItX XML from the configured intake folders. New configurations are prefilled with instance-owned folders under `/var/lib/koha/<instance>/editx/`:

- `tmp`
- `load`
- `archive`
- `fail`
- `failed_archived`

These folder paths can still be overridden with other absolute paths, for example to place archive copies on a different mounted disk. Saving the configuration validates that each folder is an absolute path, does not use parent-directory segments, and either already exists as a writable directory or can be created below a writable existing parent directory.

The plugin implements Koha's `cronjob_nightly` hook, so the normal Koha nightly plugin cron can download SFTP files and import them.

Configure SFTP sources and folder sources from the plugin configuration page. Each source has its own `Active` flag. Nightly synchronization scans active sources only; inactive sources remain saved for later use.

SFTP sources use strict host key checking by default. Leave the local target empty to use the temporary download folder from the import folder configuration. The normal production policy is to keep vendor remote files after download and rely on local duplicate detection for idempotency.

Folder sources can import EDItX files dropped by another transfer process. They support a local source directory, file pattern, successful-file action, optional local archive directory, and minimum file age.

The operations page supports manual runs:

- The staged workflow checks remote/source files, downloads or stages selected files for preview, and then imports selected local files.
- The full manual run uses the saved active sources and import folders directly for short preproduction checks. The nightly plugin cron remains the normal production path.

The same configuration page includes the EDItX runtime log level and a recent log viewer. The log covers plugin configuration, manual and nightly synchronization, SFTP downloads, EDItX parsing, validation, file moves, and order creation. The log file is written under Koha `logdir` when available, with a temporary-directory fallback.

Koha packages already run `/usr/share/koha/bin/cronjobs/plugins_nightly.pl` from `koha-common.cron.daily`. For preproduction testing, you can run only this plugin with:

`koha-foreach --chdir --enabled /usr/share/koha/bin/cronjobs/plugins_nightly.pl -m name=EDItX-plugin`

For preproduction testing, check these Koha settings before enabling nightly synchronization:

- Plugin import folder paths exist and are writable by `<instance>-koha`, or their nearest existing parent directory is writable so Koha can create the missing hierarchy.
- Each SFTP source either leaves `local_dir` empty or sets it to the same directory as `import_tmp_path`.
- The configured `authoriser` is an existing Koha borrowernumber.
- `allowed_locations` and `productform_alternative_triggers` match Koha LOC authorised values.
- The vendor has an enabled `vendor_edi_accounts` row with `transport='FILE'`, `orders_enabled='1'`, `san` matching the EDItX `BuyerParty/PartyID/Identifier`, and qualifier `91`.
- All EDItX `FundNumber` values exist in `aqbudgets.budget_code`.
- Branch, location, item type, authorised value, and item field mappings match the delivered EDItX codes.
