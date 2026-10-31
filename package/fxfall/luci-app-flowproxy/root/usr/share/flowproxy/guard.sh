#!/bin/sh
set -f
umask 077
mkdir -p /tmp/flowproxy
exec 9>/var/lock/flowproxy-guard.lock
flock -n 9 || exit 0
. /usr/share/flowproxy/guard-lib.sh
FP_PAUSE_FILE=/tmp/flowproxy/guard-paused
trap 'exit 0' TERM INT
number() {
    local value
    value=$(uci -q get "flowproxy.global.$1")
    case "$value" in ''|*[!0-9]*) value=$2 ;; esac
    [ "$value" -ge "$3" ] && [ "$value" -le "$4" ] || value=$2
    printf '%s\n' "$value"
}
fp_service_running() { [ -f /var/run/flowproxy.running ]; }
fp_probe_device() {
    /usr/sbin/flowproxy-health "$FP_SERVER" "$FP_SOCKS_PORT" "$FP_TIMEOUT" || return 1
    # A deliberately paused service has no running DNS bridge.
    if [ ! -f "$FP_PAUSE_FILE" ] &&
       [ "$(uci -q get flowproxy.global.domain_direct_enabled)" = 1 ] &&
       [ -n "$(uci -q get flowproxy.global.direct_domain_suffix)$(uci -q get flowproxy.global.direct_domain_keyword)" ]; then
        local pid
        pid=$(cat /tmp/flowproxy/dns.ready 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        kill -0 "$pid" 2>/dev/null || return 1
    fi
}
fp_probe_node() {
    local urls url code
    urls=$(uci -q get flowproxy.global.node_probe_url)
    [ -n "$urls" ] || urls=https://www.youtube.com/generate_204
    for url in $urls; do
        case "$url" in https://*) ;; *) continue ;; esac
        code=$(curl --noproxy '' --socks5-hostname "$FP_SERVER:$FP_SOCKS_PORT" \
            --proto '=https' --proto-redir '=https' --location --max-redirs 2 \
            --connect-timeout "$FP_TIMEOUT" --max-time "$FP_TIMEOUT" \
            --max-filesize 65536 --silent --output /dev/null --write-out '%{http_code}' "$url") || continue
        case "$code" in 2[0-9][0-9]) return 0 ;; esac
    done
    return 1
}
fp_guard_status() {
    local paused=0
    [ ! -f "$FP_PAUSE_FILE" ] || paused=1
    printf '{"state":"%s","paused":%s,"failures":%s,"successes":%s,"checked_at":%s}\n' \
        "$1" "$paused" "$fp_bad" "$fp_good" "$(date +%s)" > /tmp/flowproxy/health.json.next
    mv /tmp/flowproxy/health.json.next /tmp/flowproxy/health.json
}
fp_log() {
    logger -t flowproxy-guard "$*"
    printf '[%s] [warn] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> /var/log/flowproxy.log
}
fp_guard_pause() {
    printf '%s\n' "$1" > "$FP_PAUSE_FILE"
    if FLOWPROXY_GUARD_ACTION=1 /etc/init.d/flowproxy stop; then
        fp_log "$1 health check failed repeatedly; restored direct routing and original DNS"
        return 0
    fi
    fp_log 'Failed to stop FlowProxy for fallback; retrying'
    rm -f "$FP_PAUSE_FILE"
    return 1
}
fp_guard_resume() {
    if FLOWPROXY_GUARD_ACTION=1 /etc/init.d/flowproxy start && fp_service_running; then
        rm -f "$FP_PAUSE_FILE"
        fp_log 'Health checks recovered; restored FlowProxy'
        return 0
    fi
    fp_log 'FlowProxy recovery failed; retaining direct fallback'
    return 1
}
while :; do
    FP_ENABLED=$(uci -q get flowproxy.global.enabled)
    [ "$FP_ENABLED" = 1 ] || exit 0
    FP_DEVICE_FALLBACK=$(uci -q get flowproxy.global.device_fallback_enabled || echo 1)
    FP_NODE_FALLBACK=$(uci -q get flowproxy.global.node_fallback_enabled || echo 0)
    FP_SERVER=$(uci -q get flowproxy.global.proxy_server_ip_addr)
    FP_SOCKS_PORT=$(number health_socks_port 7890 1 65535)
    FP_TIMEOUT=$(number health_timeout 5 1 30)
    FP_INTERVAL=$(number health_interval 5 3 300)
    FP_FAILURES=$(number health_failures 3 1 20)
    FP_SUCCESSES=$(number health_successes 2 1 20)
    # Ignore intentional DNS teardown and import/reload maintenance.
    if flock -n /var/lock/procd_flowproxy.lock -c true &&
       flock -n /var/lock/flowproxy-import.lock -c true; then
        fp_guard_step
    else
        fp_bad=0; fp_good=0; fp_last_failure=''
    fi
    sleep "$FP_INTERVAL" & wait $!
done
