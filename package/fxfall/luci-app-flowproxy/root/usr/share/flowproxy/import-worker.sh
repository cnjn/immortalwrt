#!/bin/sh
set -eu
umask 077
work=$1
case "$work" in /tmp/flowproxy-import.*) ;; *) exit 2 ;; esac
case "${work#/tmp/flowproxy-import.}" in ''|*[!A-Za-z0-9]*) exit 2 ;; esac
results=/tmp/flowproxy/import-results
mkdir -p "$results"
/usr/share/flowproxy/import-config.sh "$work" > "$work/response.json" 2>"$work/error.log" || true
/usr/bin/ucode /usr/share/flowproxy/config-transfer.uc result "$work" > "$results/${work##*/}.json.next"
mv "$results/${work##*/}.json.next" "$results/${work##*/}.json"
# Keep recent compact results, not copies of all uploaded configurations.
find "$results" -type f -mtime +1 -exec rm -f '{}' ';'
rm -rf "$work"
