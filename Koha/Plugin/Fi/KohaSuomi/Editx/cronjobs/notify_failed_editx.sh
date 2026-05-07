#!/bin/sh
# Send e-mail notifications of failed EDItX processing to people defined in plugin configuration.
# Written by Kodo Korkalo / Koha-Suomi Oy, GNU GPL3 or later applies.

die() { printf '%s\n' "$*" ; exit 1 ; }

# Get, set and check variables

export xmllint="$(which xmllint)"
test -n "$xmllint" || die "No xmllint, apt install libxml2-utils."

mailer="$(which mail)"
test -n "$mailer" || die "No mail, apt install heirloom-mailx."

test -e "$KOHA_CONF" || die "No KOHA_CONF."

config_loader="$(dirname "$0")/exportEditXConfig.pl"
test -e "$config_loader" || die "No EDItX config exporter $config_loader."
config_exports="$("$config_loader")" || die "Could not read EDItX plugin configuration."
eval "$config_exports"

test -n "$mailfrom" && mailfrom="-r $mailfrom"
test -n "$mailto" || die "No one to send notifications to in EDItX plugin configuration."

test -n "$tmp_path" || die "No path to incoming EDItX messages in plugin configuration."
test -n "$failed_path" || die "No path to failed EDItX messages in plugin configuration."
test -n "$failed_archived_path" || die "No path to failed_archived EDItX messages in plugin configuration."
test -n "$log_path" || die "No path to logs in $KOHA_CONF."

# Get EDItX errors related to Elasticsearch and send emails

export result="$( grep -B 1 Elasticsearch $log_path/editx/error.log)"
if test -n "$result"; then
  (

    printf "\nSeuraavat EDItX sanomat on saatettu käsitellä tuplasti (Elasticsearch-virhe):\n\n"
    printf "$result\n"
    
    printf "\n"
    printf "Katso lisätietoja EDItX rajapinnan parametroinnista ja tyypillisten virhetilanteiden korjaamisesta:\n"
    printf "https://koha-suomi.fi/dokumentaatio/editx/#43-erilaisia-virhetilanteita.\n"
  ) | $mailer $mailfrom -s "EDItX tilaussanomien käsittelyssä oli ongelmia (Elasticsearch)" $mailto
fi

# Get postponed and failed EDItX notices and send emails

export pending_files="$(ls -1 $tmp_path/*.xml 2> /dev/null)"
export failed_files="$(ls -1 $failed_path/*.xml 2> /dev/null)"

test -z "$pending_files" && test -z "$failed_files" && exit 0 # Exit if nothing to report

(

  if test -n "$pending_files"; then

    printf "\nSeuraavat EDItX sanomat odottavat edelleen käsittelyä:\n\n"

    printf "Sanomien muodostamisessa aineistontoimittajan järjestelmässä tai niiden siirrossa Koha-palvelimelle\n"
    printf "on tapahtunut virhe, tai siirto palvelimelle on edelleen kesken.\n\n"

    for file in $pending_files; do
    
      printf "Ote rajapinnan virhelokista ($log_path/editx/error.log):\n"
      
      sed -n "H; /^-- Validating file $(basename $file)/h; \${g;p;}" "$log_path/editx/error.log" | sed '1d' | grep -m 1 "$(basename $file)"

      if test $(stat -c %Y "$file") -lt $(($(date +%s) - 604800)); then
        printf "Sanoma $file vanhentunut ja se -hylätään-. Arkistoidaan hakemistoon $failed_archived_path.\n"
        mv "$file" "$failed_archived_path/"
      else
        printf "Sanoma $file on jätetty käsittelyjonoon ($tmp_path) odottamaan täydennystä.\n"
      fi

      printf "\n"

    done

  fi

  if test -n "$failed_files"; then

    printf "Seuraavien EDItX sanomien käsittelyssä oli ongelmia:\n"

    for file in $failed_files; do

      printf "\n=== Sanoma: $(basename $file) ===\n\n"
      
      printf "Ote rajapinnan virhelokista ($log_path/editx/error.log):\n"
      
      sed -n "H; /^-- Validating file $(basename $file)/h; \${g;p;}" "$log_path/editx/error.log" | sed '1d' | grep --text "$(basename $file)"
      
      unset affected_locations
      for location in $($xmllint --xpath "*/ItemDetail/CopyDetail/DeliverToLocation" $file | sed 's/<\/*DeliverToLocation\/*>/\n/ig' | sort -u); do
        affected_locations="$affected_locations $location"
      done

      if test -n "$affected_locations"; then
        printf "\nSanoma koskee sijainteja/tilejä:$affected_locations\n"
      else
        printf "\nSijoitus- ja tilitietoja ei löytynyt sanomasta.\n"
      fi

      if ! xmllint --noout "$file" 2> /dev/null ; then
        printf "\nSanoma on formaatiltaan virheellinen."
        mv "$file" "$failed_archived_path/"
        continue
      fi

    done

  fi 

  printf "Katso lisätietoja EDItX rajapinnan parametroinnista ja tyypillisten virhetilanteiden korjaamisesta:\n"
  printf "https://koha-suomi.fi/dokumentaatio/editx/#43-erilaisia-virhetilanteita.\n"

) | $mailer $mailfrom -s "EDItX tilaussanomien käsittelyssä oli ongelmia" $mailto

# All done, exit gracefully
exit 0
