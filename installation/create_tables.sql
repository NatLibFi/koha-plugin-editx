
RENAME TABLE IF EXISTS `sequences` TO `koha_plugin_fi_kohasuomi_editx_sequences`;
RENAME TABLE IF EXISTS `map_productform` TO `koha_plugin_fi_kohasuomi_editx_map_productform`;

CREATE TABLE IF NOT EXISTS `koha_plugin_fi_kohasuomi_editx_sequences` (
  `invoicenumber` int(11) NOT NULL,
  `item_barcode_nextval` int(11) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `koha_plugin_fi_kohasuomi_editx_sequences` (invoicenumber, item_barcode_nextval)
SELECT 0, 0
WHERE NOT EXISTS (
  SELECT 1 FROM `koha_plugin_fi_kohasuomi_editx_sequences`
);

CREATE TABLE IF NOT EXISTS `koha_plugin_fi_kohasuomi_editx_map_productform` (
  `onix_code` varchar(10) NOT NULL,
  `productform` varchar(10) DEFAULT NULL,
  `productform_alternative` varchar(10) DEFAULT NULL,
  PRIMARY KEY (`onix_code`),
  KEY `fk_productform_itemtypes` (`productform`),
  KEY `fk_productformalt_itemtypes` (`productform_alternative`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
