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

Install the KPZ and configure the plugin from Koha staff interface. The configuration page stores EDItX settings in Koha `plugin_data`.

The legacy `/etc/koha/sites/<instance>/procurement-config.xml` file is still read as a fallback when plugin settings have not been saved yet. New installs should use the web configuration page instead.

## Nightly EDItX synchronization

The plugin importer reads incoming EDItX XML from `import_tmp_path` in the plugin configuration page. New configurations are prefilled with instance-owned folders under `/var/lib/koha/<instance>/spool/editx/`:

- `tmp`
- `load`
- `archive`
- `fail`
- `failed_archived`

These folder paths can still be overridden with other absolute paths, for example to place archive copies on a different mounted disk. Saving the configuration validates that each folder is an absolute path, does not use parent-directory segments, and either already exists as a writable directory or can be created below a writable existing parent directory.

The plugin implements Koha's `cronjob_nightly` hook, so the normal Koha nightly plugin cron can download SFTP files and import them.

Configure SFTP sources from the plugin configuration page. The YAML field accepts one or more sources:

```yaml
sources:
  - id: alexandria_library
    host: sftp.example.org
    port: 22
    user: editx-user
    identity_file: /var/lib/koha/<instance>/.ssh/editx_sftp
    remote_dir: /out/alexandria
    local_dir:
    pattern: "*.xml"
    after_download: keep
    remote_archive_dir:
    known_hosts_file:
    strict_host_key_checking: "yes"
    ssh_config:
```

Leave `local_dir` empty to use `import_tmp_path` from the plugin configuration page.

Enable automatic synchronization from the plugin configuration page. When the checkbox is disabled, `cronjob_nightly` returns without doing any work.
The operations page also has a manual download and import test action. It first shows a confirmation summary of the saved SFTP sources and import folders, then uses the last saved plugin configuration after confirmation. This action is intended for short preproduction checks; the nightly plugin cron remains the normal production path.

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
