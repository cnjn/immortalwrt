#!/bin/sh
. /usr/share/flowproxy/policy.sh
fp_policy_load || exit 1
[ "$FP_DOMAIN_ACTIVE" = 1 ] || exit 0
[ -f /var/run/flowproxy.running ] || exit 0
/usr/sbin/flowproxy-dns /tmp/flowproxy/dns.conf --warm
