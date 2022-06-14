#!/bin/sh
# requeue_failed_editx.sh (C)2016-2022 Koha-Suomi Oy
#
# This work 'as-is' we provide. No warranty express or implied.
# We've done our best to debug and test.
# Liability for damages denied.
# 
# Permission is granted hereby to copy, share, and modify.
# Use as is fit, free or for profit.
# These rights, on this notice, rely.
#
# You will need to set the cronjob, with something like:
#
# 00 7-21 * * * TRIGGER cronjobs/requeueFailedEDItX.sh

die() { printf "$@\n" ; exit 1 ; }

# Get, set and check variables

export xmllint="$(which xmllint)"
test -n "$xmllint" || die "No xmllint, apt install libxml2-utils."

test -e "$KOHA_CONF" || die "No KOHA_CONF."

config_file="$(dirname $KOHA_CONF)/procurement-config.xml"
test -e "$config_file" || die "No procurement config $config_file."

export tmp_path=$($xmllint --xpath '*/settings/import_tmp_path/text()' $config_file 2> /dev/null)
export failed_path=$($xmllint --xpath '*/settings/import_failed_path/text()' $config_file 2> /dev/null)
export failed_archived_path=$($xmllint --xpath '*/settings/import_failed_archived_path/text()' $config_file 2> /dev/null)
export log_path=$($xmllint --xpath 'yazgfs/config/logdir/text()' $KOHA_CONF 2> /dev/null)

test -n "$tmp_path" || die "No path to incoming EDItX messages in $config_file."
test -n "$failed_path" || die "No path to failed EDItX messages in $config_file."
test -n "$failed_archived_path" || die "No path to failed_archived EDItX messages in $config_file."
test -n "$log_path" || die "No path to logs in $KOHA_CONF."

# Get postponed and failed EDItX notices and requeue or discard them as needed

export pending_files="$(ls -1 $tmp_path/*.xml 2> /dev/null)"
export failed_files="$(ls -1 $failed_path/*.xml 2> /dev/null)"

test -z "$pending_files" && test -z "$failed_files" && exit 0 # Exit if nothing to do 

for file in $pending_filed; do

  if test $(stat -c %Y "$file") -lt $(($(date +%s) - 604800)) ; then
    printf "$(date) $file is expired, moved to $failed_archived_path.\n"
    mv "$file" "$failed_archived_path/"
    continue
  else
    printf "$(date) $file is incomplete, still in queue ($tmp_path).\n"
    continue
  fi

done

for file in $failed_files; do

  if ! xmllint --noout "$file" 2> /dev/null ; then
    printf "$(date) $file is invalid, moved to $failed_archived_path.\n"
    mv "$file" "$failed_archived_path/"
    continue
  fi

  if test $(stat -c %Y "$file") -lt $(($(date +%s) - 604800)) ; then
    printf "$(date) $file is expired, moved to $failed_archived_path.\n"
    mv "$file" "$failed_archived_path/"
    continue
  fi

  printf "$(date) $file is re-queued to $tmp_path.\n"
  mv "$file" "$tmp_path/"

done

# All done, exit gracefully
exit 0