#!/bin/sh
# Read-only helpers shared by rule generation and the updater.
fp_service_file() {
    case "$1" in apple|microsoft) ;; *) return 1 ;; esac
    local path="${FP_SERVICE_CACHE:-/etc/flowproxy/service-ips}/$1.cidr"
    [ -s "$path" ] || path="/usr/share/flowproxy/service-ips/$1.cidr"
    printf '%s\n' "$path"
}

fp_service_validate() {
    LC_ALL=C awk '
        NF {
            if ($0 !~ /^[0-9.]+\/[0-9]+$/ || ++count>4096) exit 1
            if(split($0,c,"/")!=2 || c[2]<8 || c[2]>32 || split(c[1],a,".")!=4) exit 1
            for(i=1;i<=4;i++) if(a[i]!~/^[0-9]+$/ || a[i]>255 || (length(a[i])>1 && substr(a[i],1,1)=="0")) exit 1
            if(a[1]==0 || a[1]==10 || a[1]==127 || a[1]>=224 ||
               (a[1]==169 && a[2]==254) || (a[1]==172 && a[2]>=16 && a[2]<=31) ||
               (a[1]==192 && a[2]==168) || (a[1]==100 && a[2]>=64 && a[2]<=127)) exit 1
            print $0
        }
        END { if(!count) exit 1 }' "$1"
}

fp_service_elements() {
    local path ranges
    path=$(fp_service_file "$1") || return 1
    ranges=$(fp_service_validate "$path") || return 1
    printf '%s\n' "$ranges" | awk 'NF {printf "%s%s",n++ ? ", " : "",$0}'
}
