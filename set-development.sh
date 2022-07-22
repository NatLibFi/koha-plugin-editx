#!/bin/bash

kohaplugindir="$(grep -Po '(?<=<pluginsdir>).*?(?=</pluginsdir>)' $KOHA_CONF)"
kohadir="$(grep -Po '(?<=<intranetdir>).*?(?=</intranetdir>)' $KOHA_CONF)"

rm -r $kohaplugindir/Koha/Plugin/Fi/KohaSuomi/Editx
rm $kohaplugindir/Koha/Plugin/Fi/KohaSuomi/Editx.pm

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

ln -s "$SCRIPT_DIR/Koha/Plugin/Fi/KohaSuomi/Editx" $kohaplugindir/Koha/Plugin/Fi/KohaSuomi/Editx
ln -s "$SCRIPT_DIR/Koha/Plugin/Fi/KohaSuomi/Editx.pm" $kohaplugindir/Koha/Plugin/Fi/KohaSuomi/Editx.pm

rm $kohadir/misc/cronjobs/generate_okm_annual_statistics.pl
ln -s $kohaplugindir/Koha/Plugin/Fi/KohaSuomi/Editx/cronjobs/generate_okm_annual_statistics.pl $kohadir/misc/cronjobs/generate_okm_annual_statistics.pl

rm $kohadir/misc/cronjobs/update_biblio_data_elements.pl
ln -s $kohaplugindir/Koha/Plugin/Fi/KohaSuomi/Editx/cronjobs/update_biblio_data_elements.pl $kohadir/misc/cronjobs/update_biblio_data_elements.pl

perl $kohadir/misc/devel/install_plugins.pl