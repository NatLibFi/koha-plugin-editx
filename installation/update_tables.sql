-- Plugin upgrade() performs table migration in portable Perl/DBI code.

ALTER TABLE `koha_plugin_fi_kohasuomi_editx_map_productform`
  MODIFY `productform` varchar(10) DEFAULT NULL,
  MODIFY `productform_alternative` varchar(10) DEFAULT NULL;
