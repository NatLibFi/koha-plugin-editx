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

Add procurement-config.xml file to config dir and check paths exist.

example:

```
<?xml version="1.0"?>
<data>
  <settings>
        <use_finna_materialtype>no</use_finna_materialtype> <!-- Do we put finna materialtype into 942c? default "no" -->
        <import_tmp_path>/home/koha/koha-dev/var/spool/editx/tmp</import_tmp_path> <!-- The folder where files should be first put. The Integrations external entrypoint -->
        <import_load_path>/home/koha/koha-dev/var/spool/editx/load</import_load_path> <!-- The path from where the script reads files to import -->
        <import_archive_path>/home/koha/koha-dev/var/spool/editx/archive</import_archive_path> <!-- The path where files are archived after succesfull import-->
        <import_failed_path>/home/koha/koha-dev/var/spool/editx/fail</import_failed_path> <!-- The path where files are archived if something fails during import-->
        <import_failed_archived_path>/home/koha/koha-dev/var/spool/editx/failed_archived</import_failed_archived_path> <!-- The path where files are archived if something fails during import-->
        <authoriser>0</authoriser> <!-- A borrowers id used in import, change this! -->
        <allowed_locations>LAP,AIK,MUS</allowed_locations>
        <productform_alternative_triggers>LAP</productform_alternative_triggers> <!-- The shelving location that is found in fundnumber, used for assigning productform_alternative from db map_productform-->
        <automatch_biblios>yes</automatch_biblios> <!-- Set to 'no' if you want to create a new biblio and biblioitem on every order. -->
    </settings>
    <notifications>
        <mailto>notification@address</mailto> <!-- comma separated list of email-addresses to send error reports to -->
        <!-- <mailfrom>set_from_address@here</mailfrom> --> <!-- optionally set the address to be used as "from" in failure notifications -->
    </notifications>
</data>
```
