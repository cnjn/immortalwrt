#!/bin/sh
set -eu
. /usr/share/flowproxy/service_ips.sh
CACHE=/etc/flowproxy/service-ips
RUNTIME=/tmp/flowproxy/service-ips

enabled() { [ "$(uci -q get "flowproxy.global.${1}_ip_direct_enabled" || echo 0)" = 1 ]; }

status() {
    local vendor="$1" result="$2" previous=0
    [ ! -s "$CACHE/$vendor.json" ] || previous=$(jsonfilter -i "$CACHE/$vendor.json" -e '@.last_success' 2>/dev/null || echo 0)
    [ "$result" != ok ] || previous=$(date +%s)
    printf '{"last_success":%s,"last_attempt":%s,"result":"%s"}\n' "${previous:-0}" "$(date +%s)" "$result" > "$CACHE/$vendor.json.next"
    mv "$CACHE/$vendor.json.next" "$CACHE/$vendor.json"
}

download() {
    curl --noproxy '*' --proto '=https' --tlsv1.2 --fail --silent --show-error \
        --connect-timeout 8 --max-time 40 --max-filesize 1048576 "$@"
}

fetch() {
    local vendor="$1" work="$2" id
    case "$vendor" in
        apple)
            download -H 'Accept: application/vnd.github.raw+json' \
                'https://api.github.com/repos/blackmatrix7/ios_rule_script/contents/rule/Clash/Apple/Apple.list' \
                -o "$work/raw" || return 1
            awk -F, '$1=="IP-CIDR" { print $2 }' "$work/raw" > "$work/input"
            # The list must retain the Apple-owned block documented by Apple.
            grep -qx '17.0.0.0/8' "$work/input" || return 1
            ;;
        microsoft)
            id=$(cat /proc/sys/kernel/random/uuid)
            : > "$work/input"
            for instance in worldwide China; do
                download "https://endpoints.office.com/endpoints/$instance?clientrequestid=$id" -o "$work/$instance.json" || return 1
                jsonfilter -i "$work/$instance.json" -e '@[*].ips[*]' > "$work/ips" || return 1
                awk 'index($0,":")==0 { if(index($0,"/")==0) print $0 "/32"; else print }' "$work/ips" >> "$work/input"
            done
            ;;
        *) return 1 ;;
    esac
    fp_service_validate "$work/input" > "$work/validated" || return 1
    LC_ALL=C sort -u "$work/validated" > "$work/next.cidr"
    awk 'BEGIN {print "table inet fp_service_validate {\n set addresses {\n type ipv4_addr\n flags interval\n auto-merge\n elements = {"}
         NF {printf "%s%s",n++ ? ", " : "",$0}
         END {print " }\n }\n}"}' "$work/next.cidr" > "$work/check.nft"
    nft -c -f "$work/check.nft" || return 1
}

publish() {
    local vendor="$1" work="$2" set="fp_${1}_service_v4"
    # Reuse procd's lock so reload and set replacement cannot race. Downloads do
    # not hold this lock and therefore never delay an ordinary service reload.
    (
        flock -x 8
        if enabled "$vendor" && [ -f /var/run/flowproxy.running ] && nft list set inet flowproxy "$set" >/dev/null 2>&1; then
            {
                printf 'flush set inet flowproxy %s\nadd element inet flowproxy %s { ' "$set" "$set"
                awk 'NF {printf "%s%s",n++ ? ", " : "",$0}' "$work/next.cidr"
                printf ' }\n'
            } > "$work/apply.nft"
            nft -c -f "$work/apply.nft" && nft -f "$work/apply.nft" || exit 1
        fi
        if ! cmp -s "$work/next.cidr" "$CACHE/$vendor.cidr"; then
            cp "$work/next.cidr" "$CACHE/$vendor.cidr.next"
            mv "$CACHE/$vendor.cidr.next" "$CACHE/$vendor.cidr"
        fi
    ) 8>/var/lock/procd_flowproxy.lock
}

once() {
    mkdir -p "$CACHE" "$RUNTIME"
    exec 9>/var/lock/flowproxy-service-ips.lock
    flock -n 9 || return 0
    local vendor work failed=0 last now
    for vendor in apple microsoft; do
        enabled "$vendor" || continue
        now=$(date +%s)
        if [ "${1:-}" = due ] && [ -s "$CACHE/$vendor.json" ]; then
            last=$(jsonfilter -i "$CACHE/$vendor.json" -e '@.last_success' 2>/dev/null || echo 0)
            [ "$((now-${last:-0}))" -ge 86400 ] || continue
        fi
        work=$(mktemp -d "$RUNTIME/$vendor.XXXXXX")
        if fetch "$vendor" "$work" && publish "$vendor" "$work"; then
            status "$vendor" ok
            logger -t flowproxy-service-ips "$vendor IPv4 list verified and applied"
        else
            status "$vendor" failed
            logger -t flowproxy-service-ips "$vendor update failed; keeping the last valid list"
            failed=1
        fi
        rm -rf "$work"
    done
    flock -u 9
    exec 9>&-
    return "$failed"
}

case "${1:---once}" in
    --once) once ;;
    --watch)
        trap 'exit 0' TERM INT
        while :; do
            once due || true
            sleep 3600 & wait $!
        done
        ;;
    *) echo 'usage: update_service_ips.sh [--once|--watch]' >&2; exit 2 ;;
esac
