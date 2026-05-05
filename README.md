# Koha-Suomi plugin Editx
Adds EDItX import support for Koha
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

Check "installation" folder for needed resources:

Add procurement-config.xml file to Koha instance config dir (/etc/koha/sites/instance/) and update path variables inside procurement-config.xml.

Place installation/koha-common-editx crontab file to /etc/cron.d/ folder and change that file contents.

Create requred SQL tables by commands (consider that $KOHA_INSTANCE should be YOUR instance):
```
    KOHA_INSTANCE=library; mysql -u ${KOHA_INSTANCE}_main -p ${KOHA_INSTANCE}_main < installation/create_tables.sql
```

## Fetching EDItX files from SFTP

The plugin importer reads incoming EDItX XML from `import_tmp_path` in `/etc/koha/sites/<instance>/procurement-config.xml`. The helper script `Koha/Plugin/Fi/KohaSuomi/Editx/cronjobs/fetch_editx_sftp.sh` can be scheduled before `runEditXImport.pl` to download SFTP files into that directory.

Copy `installation/editx-sftp.conf.example` to `/etc/koha/sites/<instance>/editx-sftp.conf`, set the SFTP host, user, SSH key, host key file, remote folder, and `SFTP_LOCAL_DIR`. Keep credentials and routing outside git.

The recommended cron order is:

```
*/5 * * * * <instance>-koha /var/lib/koha/<instance>/plugins/Koha/Plugin/Fi/KohaSuomi/Editx/cronjobs/fetch_editx_sftp.sh
*/5 * * * * <instance>-koha /var/lib/koha/<instance>/plugins/Koha/Plugin/Fi/KohaSuomi/Editx/cronjobs/runEditXImport.pl
```

For 3AMK preproduction testing, check these Koha settings before enabling the cron jobs:

- `procurement-config.xml` paths exist and are writable by `<instance>-koha`.
- `SFTP_LOCAL_DIR` equals `import_tmp_path`.
- The vendor has an enabled `vendor_edi_accounts` row with `transport='FILE'`, `orders_enabled='1'`, `san` matching the EDItX `BuyerParty/PartyID/Identifier`, and qualifier `91`.
- All EDItX `FundNumber` values exist in `aqbudgets.budget_code`.
- Branch, location, item type, authorised value, and item field mappings match the delivered 3AMK codes.
