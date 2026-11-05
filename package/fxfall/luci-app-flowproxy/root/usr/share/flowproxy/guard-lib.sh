#!/bin/sh
# State machine shared by the daemon and isolated failure/recovery tests.
fp_bad=0
fp_good=0
fp_last_failure=''
fp_guard_step() {
    local paused=0 failure='' state=healthy
    [ ! -f "$FP_PAUSE_FILE" ] || paused=1
    if [ "$FP_ENABLED" != 1 ]; then
        rm -f "$FP_PAUSE_FILE"
        fp_bad=0; fp_good=0; fp_last_failure=''
        fp_guard_status inactive
        return
    fi
    if [ "$paused" = 0 ] && ! fp_service_running; then
        # A manual stop must never be undone by the watchdog.
        fp_bad=0; fp_good=0; fp_last_failure=''
        fp_guard_status inactive
        return
    fi
    if [ "$FP_DEVICE_FALLBACK$FP_NODE_FALLBACK" = 00 ]; then
        fp_bad=0; fp_good=0; fp_last_failure=''
        if [ "$paused" = 1 ]; then fp_guard_resume; fi
        fp_guard_status disabled
        return
    fi
    if ! fp_probe_device; then
        if [ "$FP_DEVICE_FALLBACK" = 1 ]; then
            failure=device
        else
            # An unavailable LAN endpoint cannot establish a remote-node failure.
            fp_bad=0; fp_good=0; fp_last_failure=''
            if [ "$paused" = 1 ]; then fp_guard_status "paused_$(cat "$FP_PAUSE_FILE")";
            else fp_guard_status device_unreachable; fi
            return
        fi
    elif [ "$FP_NODE_FALLBACK" = 1 ] && ! fp_probe_node; then
        failure=node
    fi
    if [ -n "$failure" ]; then
        fp_good=0
        [ "$fp_last_failure" = "$failure" ] || fp_bad=0
        fp_last_failure=$failure
        fp_bad=$((fp_bad + 1))
        state="checking_$failure"
        if [ "$paused" = 1 ]; then
            printf '%s\n' "$failure" > "$FP_PAUSE_FILE"
            state="paused_$failure"
        elif [ "$fp_bad" -ge "$FP_FAILURES" ]; then
            fp_guard_pause "$failure" && state="paused_$failure"
        fi
    else
        fp_bad=0; fp_last_failure=''
        fp_good=$((fp_good + 1))
        if [ "$paused" = 1 ]; then
            state="paused_$(cat "$FP_PAUSE_FILE")"
            if [ "$fp_good" -ge "$FP_SUCCESSES" ] && fp_guard_resume; then
                fp_good=0; state=healthy
            fi
        fi
    fi
    # Counts saturate to prevent shell integer overflow during long uptime.
    [ "$fp_bad" -le "$FP_FAILURES" ] || fp_bad=$FP_FAILURES
    [ "$fp_good" -le "$FP_SUCCESSES" ] || fp_good=$FP_SUCCESSES
    fp_guard_status "$state"
}
