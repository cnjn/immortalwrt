#!/bin/sh
# Shared validation and canonical values; no mutations during preview.
fp_policy_load() {
 FP_APPLE=$(uci -q get flowproxy.global.apple_ip_direct_enabled || echo 0)
 FP_MICROSOFT=$(uci -q get flowproxy.global.microsoft_ip_direct_enabled || echo 0)
 FP_DOMAIN=$(uci -q get flowproxy.global.domain_direct_enabled || echo 0)
 FP_SUFFIX=$(uci -q get flowproxy.global.direct_domain_suffix | tr ' ' '\n' | awk '
 NF {s=tolower($0);sub(/^\*\./,"",s);sub(/^\+\./,"",s);sub(/\.$/,"",s);if(length(s)>253||s!~/^[a-z0-9_-]+(\.[a-z0-9_-]+)*$/)exit 1;print s}') || { echo 'Invalid domain suffix' >&2; return 1; }
 FP_KEYWORD=$(uci -q get flowproxy.global.direct_domain_keyword | tr ' ' '\n' | awk '
 NF {s=tolower($0);if(length(s)>253||s!~/^[a-z0-9_.-]+$/)exit 1; print s}') || { echo 'Invalid domain keyword' >&2; return 1; }
 FP_DIRECT_DNS=$(uci -q get flowproxy.global.direct_domain_dns || echo 223.5.5.5)
 FP_UPSTREAM=$(uci -q get flowproxy.global.proxy_server_ip_addr)
 FP_UPSTREAM_PORT=$(uci -q get flowproxy.global.proxy_server_dns_port || echo 5353)
 if [ "$(uci -q get flowproxy.global.dns_proxy_enabled)" != 1 ]; then
  FP_UPSTREAM=$(awk '$1=="nameserver" && $2 ~ /^[0-9.]+$/ {print $2; exit}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)
  [ -n "$FP_UPSTREAM" ] || FP_UPSTREAM=$FP_DIRECT_DNS
  FP_UPSTREAM_PORT=53
 fi
 [ -n "$FP_UPSTREAM" ] || FP_UPSTREAM=$FP_DIRECT_DNS
 FP_DOMAIN_ACTIVE=0
 [ "$FP_DOMAIN" = 1 ] && [ -n "$FP_SUFFIX$FP_KEYWORD" ] && FP_DOMAIN_ACTIVE=1
 for name in fp_direct_domains fp_apple_service_v4 fp_microsoft_service_v4; do
  if uci -q get "flowproxy.$name" >/dev/null; then echo "Reserved internal set name: $name" >&2; return 1; fi
 done
}
fp_dns_config() {
 printf 'listen 127.0.0.1 5533\nupstream %s %s\ndirect %s 53\n' "$FP_UPSTREAM" "$FP_UPSTREAM_PORT" "$FP_DIRECT_DNS"
 if [ "$FP_DOMAIN_ACTIVE" = 1 ]; then
  for value in $FP_SUFFIX; do printf 'suffix %s\n' "$value"; done
  for value in $FP_KEYWORD; do printf 'keyword %s\n' "$value"; done
 fi
}
