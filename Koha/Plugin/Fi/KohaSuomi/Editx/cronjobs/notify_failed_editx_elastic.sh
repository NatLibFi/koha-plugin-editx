#!/bin/sh
# Send e-mail notifications of failed EDItX processing to people defined in procurement-config
# Written by Kodo Korkalo / Koha-Suomi Oy, GNU GPL3 or later applies.

# You will need to add <notifications> part to the end of your procurement-config.xml:

# <notifications>
#   <mailto>someone@somewere.com,someone@else.com</mailto>
#   <mailfrom>someone@somewere.com</mailfrom> <!-- this is optional, [user]@[host] will be used if left unset -->
# </notifications>

die() { printf "$@\n" ; exit 1 ; }

# Get, set and check variables

export xmllint="$(which xmllint)"
test -n "$xmllint" || die "No xmllint, apt install libxml2-utils."

mailer="$(which mail)"
test -n "$mailer" || die "No mail, apt install heirloom-mailx."

test -e "$KOHA_CONF" || die "No KOHA_CONF."

config_file="$(dirname $KOHA_CONF)/procurement-config.xml"
test -e "$config_file" || die "No procurement config $config_file."

mailto=$($xmllint --xpath '*/notifications/mailto/text()' $config_file 2> /dev/null)
mailfrom=$($xmllint --xpath '*/notifications/mailfrom/text()' $config_file 2> /dev/null)

export archive_path=$($xmllint --xpath '*/settings/import_archive_path/text()' $config_file 2> /dev/null)

export log_path=$($xmllint --xpath 'yazgfs/config/logdir/text()' $KOHA_CONF 2> /dev/null)

test -n "$mailfrom" && mailfrom="-r $mailfrom"
test -n "$mailto" || die "No one to send notifications to in $config_file."

test -n "$archive_path" || die "No path to archived EDItX messages in $config_file."

test -n "$log_path" || die "No path to logs in $KOHA_CONF."

# Get postponed and failed EDItX notices and send emails

export archived_files="$(ls -1 $failed_path/*.xml 2> /dev/null)"
timestamp=$(date +"%Y-%m-%d %T")

# test -z "$archived_files" && test -z "$failed_files" && exit 0 # Exit if nothing to report

# Get EDItX errors related to Elasticsearch and send emails
result=$( grep "$(date +"%Y-%m-%d")" "$log_path/editx/error.log" | grep -B 1 "Elasticsearch" )

if [ -n "$result" ]; then

(
  printf "$timestamp"

  printf "\nSeuraavat EDItX sanomat on saatettu käsitellä tuplasti (Elasticsearch-virhe):\n\n"
  printf '%s\n' "$result"
    
  printf "\n"
  printf "Katso lisätietoja EDItX rajapinnan parametroinnista ja tyypillisten virhetilanteiden korjaamisesta:\n"
  printf "https://tiketti.koha-suomi.fi/projects/koha-suomen-dokumentaatio/wiki/EditX-hankinta#43-Erilaisia-virhetilanteita\n"

) | $mailer $mailfrom -s "EDItX tilaussanomien käsittelyssä oli ongelmia (Elasticsearch)" $mailto
fi

#All done, exit gracefully


