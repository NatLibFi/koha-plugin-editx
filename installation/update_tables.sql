
RENAME TABLE IF EXISTS `sequences` TO `koha_plugin_fi_kohasuomi_editx_sequences`;
RENAME TABLE IF EXISTS `map_productform` TO `koha_plugin_fi_kohasuomi_editx_map_productform`;
RENAME TABLE IF EXISTS `editx_sequences` TO `koha_plugin_fi_kohasuomi_editx_sequences`;
RENAME TABLE IF EXISTS `editx_map_productform` TO `koha_plugin_fi_kohasuomi_editx_map_productform`;

ALTER TABLE `koha_plugin_fi_kohasuomi_editx_map_productform`
  MODIFY `productform` varchar(10) DEFAULT NULL,
  MODIFY `productform_alternative` varchar(10) DEFAULT NULL;
