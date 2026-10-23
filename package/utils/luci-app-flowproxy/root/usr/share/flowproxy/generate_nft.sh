#!/bin/sh
# Generate nftables configuration for flowproxy

. /lib/functions.sh

[ -n "$UCI_CONFIG_DIR" ] && export UCI_CONFIG_DIR

CONFIG="flowproxy"
NFT_TABLE="flowproxy"
OUTPUT_FILE="/tmp/flowproxy/nft.conf"

mkdir -p "$(dirname "$OUTPUT_FILE")"

ENABLED_SETS=" "

log_debug() {
	[ "$FLOWPROXY_LOG_LEVEL" = "debug" ] && echo "DEBUG: $*" >&2
}

gen_set_definition() {
	local section="$1"
	local type enabled auto_gen file_path elems is_interval
	
	enabled=$(uci -q get "$CONFIG.$section.enabled")
	[ "$enabled" = "0" ] && { log_debug "Set $section is disabled, skipping"; return; }

	log_debug "Generating set: $section"
	ENABLED_SETS="${ENABLED_SETS}@${section} "
	type=$(uci -q get "$CONFIG.$section.type")
	[ -z "$type" ] && type="ipv4_addr"
	
	if [ "$section" = "private_dst_ip_v4" ]; then
		auto_gen=$(uci -q get "$CONFIG.$section.auto_generate")
		if [ "$auto_gen" = "1" ] || [ -z "$auto_gen" ]; then
			elems="10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16"
		fi
	fi
	
	local uci_elems=""
	for e in $(uci -q get "$CONFIG.$section.elements"); do
		[ -n "$uci_elems" ] && uci_elems="${uci_elems}, "
		uci_elems="${uci_elems}${e}"
	done
	[ -n "$uci_elems" ] && { [ -n "$elems" ] && elems="${elems}, "; elems="${elems}${uci_elems}"; }

	file_path=$(uci -q get "$CONFIG.$section.file_path")
	download_url=$(uci -q get "$CONFIG.$section.download_url")
	if [ -n "$download_url" ] && [ -n "$file_path" ]; then
		if [ ! -f "$file_path" ]; then
			echo "Downloading $section data from $download_url to $file_path..." >&2
			wget -q -O "$file_path" "$download_url" --timeout=10 --no-check-certificate
			[ $? -ne 0 ] && { echo "Failed to download $section data" >&2; rm -f "$file_path"; }
		fi
	fi

	if [ -n "$file_path" ] && [ -f "$file_path" ]; then
		local file_elems=$(get_file_elements "$file_path")
		if [ -n "$file_elems" ]; then
			[ -n "$elems" ] && elems="${elems}, "
			elems="${elems}${file_elems}"
		fi
	fi

	case "$type" in "ipv4_addr"|"inet_service"|"ether_addr") is_interval=1 ;; *) is_interval=0 ;; esac
	[ "$is_interval" = "0" ] && { case "$elems" in */*|*-*) is_interval=1 ;; esac; }

	printf "\tset %s {\n" "$section"
	printf "\t\ttype %s\n" "$type"
	[ "$is_interval" = "1" ] && printf "\t\tflags interval\n"
	[ -n "$elems" ] && printf "\t\telements = { %s }\n" "$elems"
	printf "\t}\n\n"
}

get_file_elements() {
	local file_path="$1"
	[ ! -f "$file_path" ] && return

	if [ "$FLOWPROXY_PREVIEW" = "1" ]; then
		local total=$(wc -l < "$file_path")
		if [ "$total" -gt 100 ]; then
			awk 'BEGIN { count=0 } 
				!/^($|#)/ { 
					if (count < 100) {
						if (count > 0) {
							printf ", "
							if (count % 2 == 0) printf "\n\t\t\t     "
						}
						printf "%s", $0
						count++
					}
				} 
				END { printf ", ... (%d more items omitted for preview)", '"$total"'-100 }' "$file_path"
			return
		fi
	fi

	awk 'BEGIN { count=0 } 
		!/^($|#)/ { 
			if (count > 0) {
				printf ", "
				if (count % 2 == 0) printf "\n\t\t\t     "
			}
			printf "%s", $0
			count++
		} 
		END { print "" }' "$file_path"
}

process_rule() {
    local section="$1"; local proto="$2"
    local enabled match_type match_value action counter
    
    enabled=$(uci -q get "$CONFIG.$section.enabled"); [ "$enabled" = "0" ] && { log_debug "Rule $section is disabled, skipping"; return; }
    match_type=$(uci -q get "$CONFIG.$section.match_type")
    [ -z "$match_type" ] && match_type="dst_ip"
    match_value=$(uci -q get "$CONFIG.$section.match_value")
    
    log_debug "Processing $proto rule: $section ($match_type=$match_value)"
    action=$(uci -q get "$CONFIG.$section.action"); [ -z "$action" ] && action="return"
    counter=$(uci -q get "$CONFIG.$section.counter")
    [ -z "$match_value" ] && return

    case "$match_value" in
        @*)
            local set_ref=$(echo "$match_value" | cut -d' ' -f1)
            if ! echo "$ENABLED_SETS" | grep -q " ${set_ref} "; then
                log_debug "Skipping rule $section: set ${set_ref} is not defined or disabled"
                return
            fi
            ;;
    esac

    match_value=$(echo "$match_value" | sed -E 's/ (return|accept|drop)$//g')
    local segment=""
    case "$match_type" in
        src_mac)  segment="ether saddr $match_value ip protocol $proto" ;;
        src_ip)   segment="ip saddr $match_value ip protocol $proto" ;;
        dst_ip)   segment="ip daddr $match_value ip protocol $proto" ;;
        src_port) segment="ip protocol $proto $proto sport $match_value" ;;
        dst_port) segment="ip protocol $proto $proto dport $match_value" ;;
        *)        segment="$match_value ip protocol $proto" ;;
    esac

    local line="$segment"; [ "$counter" = "1" ] && line="$line counter"; line="$line $action"
    [ -n "$line" ] && echo "        $line"
}

SECTIONS_SET=$(uci -q show "$CONFIG" | grep "=nftset" | cut -d'.' -f2 | cut -d'=' -f1)
SECTIONS_TCP=$(uci -q show "$CONFIG" | grep "=tcp_rule" | cut -d'.' -f2 | cut -d'=' -f1)
SECTIONS_UDP=$(uci -q show "$CONFIG" | grep "=udp_rule" | cut -d'.' -f2 | cut -d'=' -f1)

if [ "$1" = "runtime" ]; then
	TRAFFIC_MARK=$(uci -q get "$CONFIG.global.traffic_mark" || echo "0x666")
	ROUTING_TABLE=$(uci -q get "$CONFIG.global.routing_table" || echo "888")
	echo "--- [ nftables live rules ] ---"
	nft list table inet "$CONFIG" 2>/dev/null | awk 'BEGIN { count=0; skip=0 } 
		/elements = \{/ { print $0; skip=1; next } 
		skip == 1 && /\}/ { printf "\t\t\t     ... (items truncated for preview)\n"; print $0; skip=0; next } 
		skip == 1 { count++; if (count < 20) print $0; next } 
		{ print $0 }' || echo "(table not found)"
	echo ""
	echo "--- [ ip rule list ] ---"
	ip rule show 2>/dev/null
	echo ""
	echo "--- [ ip route table $ROUTING_TABLE ] ---"
	ip route show table "$ROUTING_TABLE" 2>/dev/null || echo "(table empty)"
	exit 0
fi

cat > "$OUTPUT_FILE" << EOF
#!/usr/sbin/nft -f
table inet $NFT_TABLE
flush table inet $NFT_TABLE

table inet $NFT_TABLE {
EOF

for s in $SECTIONS_SET; do
    gen_set_definition "$s" >> "$OUTPUT_FILE"
done

TCP_ENABLED=$(uci -q get "$CONFIG.global.tcp_enabled" || echo "1")
UDP_ENABLED=$(uci -q get "$CONFIG.global.udp_enabled" || echo "1")
TRAFFIC_MARK=$(uci -q get "$CONFIG.global.traffic_mark" || echo "0x666")
PROXY_SERVER_IP_ADDR=$(uci -q get "$CONFIG.global.proxy_server_ip_addr")

if [ "$TCP_ENABLED" = "1" ]; then
    cat >> "$OUTPUT_FILE" << EOF
    chain LAN_MARKFLOW_TCP {
        type filter hook prerouting priority mangle; policy accept;
        fib daddr type { unspec, local, anycast, multicast } counter return
EOF
    if [ -n "$PROXY_SERVER_IP_ADDR" ]; then
        echo "        ip saddr $PROXY_SERVER_IP_ADDR ip protocol tcp counter return" >> "$OUTPUT_FILE"
    fi
    for s in $SECTIONS_TCP; do process_rule "$s" "tcp" >> "$OUTPUT_FILE"; done
    echo "        ip protocol tcp counter meta mark set $TRAFFIC_MARK" >> "$OUTPUT_FILE"
    echo "    }" >> "$OUTPUT_FILE"
fi

if [ "$UDP_ENABLED" = "1" ]; then
    cat >> "$OUTPUT_FILE" << EOF
    chain LAN_MARKFLOW_UDP {
        type filter hook prerouting priority mangle; policy accept;
        fib daddr type { unspec, local, anycast, multicast } counter return
EOF
    if [ -n "$PROXY_SERVER_IP_ADDR" ]; then
        echo "        ip saddr $PROXY_SERVER_IP_ADDR ip protocol udp counter return" >> "$OUTPUT_FILE"
    fi
    for s in $SECTIONS_UDP; do process_rule "$s" "udp" >> "$OUTPUT_FILE"; done
    echo "        ip protocol udp counter meta mark set $TRAFFIC_MARK" >> "$OUTPUT_FILE"
    echo "    }" >> "$OUTPUT_FILE"
fi
echo "}" >> "$OUTPUT_FILE"
cat "$OUTPUT_FILE"
