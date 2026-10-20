#!/usr/bin/env python3
"""Exercise the prepared fw4 resolver with ucode and realistic device graphs.

Example:
  python3 test-hardware-offload.py /path/to/prepared/fw4.uc \
      --ucode-command 'ssh root@router ucode -e'
Only the ucode interpreter runs on the router; no network configuration changes.
"""

import argparse
import json
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--ucode-command", default="ucode -e")
    args = parser.parse_args()
    source = args.source.read_text()
    lower = source[source.index("function resolve_lower_devices("):
                   source.index("function nft_json_command(")]
    start = source.index("resolve_hw_offload_devices: function()")
    resolver = source[start:source.index("resolve_offload_devices: function()", start)]
    cases = [
        {"name": "wired", "roots": ["br-lan", "lan4"],
         "status": {"br-lan": {"devtype": "bridge"}},
         "lowers": {"br-lan": ["lan1", "lan2"]},
         "capable": ["lan1", "lan2", "lan4"], "expected": ["lan1", "lan2", "lan4"]},
        {"name": "ppp_ipv6_carrier", "roots": ["lan1", "lan4", "pppoe-wan2"],
         "capable": ["lan1", "lan4"], "expected": ["lan1", "lan4"]},
        {"name": "mesh_veth_in_bridge", "roots": ["br-lan", "lan4"],
         "status": {"br-lan": {"devtype": "bridge"}},
         "lowers": {"br-lan": ["lan1", "zmesh0"]},
         "capable": ["lan1", "lan4"], "expected": ["lan1", "lan4"]},
        {"name": "dual_macvlan_pppoe_with_mesh", "roots": ["br-lan", "mv0", "mv1", "pppoe-a", "pppoe-b"],
         "status": {"br-lan": {"devtype": "bridge"},
                    "mv0": {"type": "macvlan", "devtype": "ethernet"},
                    "mv1": {"type": "macvlan", "devtype": "ethernet"}},
         "lowers": {"br-lan": ["lan1", "zmesh0"], "mv0": ["lan4"], "mv1": ["lan4"]},
         "capable": ["lan1", "lan4"], "expected": ["lan1", "lan4"]},
        {"name": "vlan_under_macvlan", "roots": ["lan1", "mv0"],
         "status": {"mv0": {"type": "macvlan", "devtype": "ethernet"},
                    "lan4.100": {"devtype": "vlan"}},
         "lowers": {"mv0": ["lan4.100"], "lan4.100": ["lan4"]},
         "capable": ["lan1", "lan4"], "expected": ["lan1", "lan4"]},
        {"name": "software_only_fallback", "roots": ["veth0", "pppoe-a"],
         "capable": [], "expected": None, "expected_enabled": False},
        {"name": "combined_driver_constraint_fallback", "roots": ["lan1", "lan4"],
         "capable": ["lan1", "lan4"], "reject_combined": True,
         "expected": None, "expected_enabled": False},
        {"name": "hardware_disabled", "roots": ["lan1", "lan4"],
         "capable": ["lan1", "lan4"], "enabled": False,
         "expected": None, "expected_enabled": False},
        {"name": "deduplicate_physical_port", "roots": ["lan1", "lan4", "lan4"],
         "capable": ["lan1", "lan4"], "expected": ["lan1", "lan4"]},
        {"name": "capability_without_netifd_feature_flag", "roots": ["lan1", "lan4"],
         "status": {}, "capable": ["lan1", "lan4"], "expected": ["lan1", "lan4"]},
    ]
    program = "let cases = " + json.dumps(cases) + ";\n"
    program += r"""
let current, probes, warnings;
let fs = {
    opendir: function(path) {
        let name = substr(path, length('/sys/class/net/'));
        let entries = map(current.lowers?.[name] || [], n => 'lower_' + n);
        let pos = 0;
        return { read: () => entries[pos++] ?? null, close: () => true };
    }
};
let ubus = { connect: () => ({
    call: () => current.status || {}, disconnect: () => true
}) };
function nft_try_hw_offload(devices) {
    push(probes, devices);
    if (!length(devices) || (current.reject_combined && length(devices) > 1))
        return false;
    for (let device in devices)
        if (index(current.capable, device) < 0)
            return false;
    return true;
}
"""
    program += lower + "\nlet target = {\n" + resolver + r"""
    state: {},
    default_option: function(name) { return this.state.defaults[name]; },
    zones: () => [{ related_physdevs: current.roots }],
    warn: message => push(warnings, message)
};
let failures = 0;
for (let test in cases) {
    current = test; probes = []; warnings = [];
    target.state = { defaults: { flow_offloading_hw: test.enabled ?? true } };
    let actual = target.resolve_hw_offload_devices();
    let enabled = target.state.defaults.flow_offloading_hw;
    let ok = sprintf('%J', actual) == sprintf('%J', test.expected) &&
        enabled == (test.expected_enabled ?? true);
    if (test.enabled === false && length(probes))
        ok = false;
    if (!ok)
        failures++;
    print(sprintf('%s %s devices=%J enabled=%J\n',
        ok ? 'PASS' : 'FAIL', test.name, actual, enabled));
}
exit(failures ? 1 : 0);
"""
    command = shlex.split(args.ucode_command)
    command.append(shlex.quote(program) if Path(command[0]).name == "ssh" else program)
    result = subprocess.run(command, text=True, capture_output=True, timeout=30)
    print(result.stdout, end="")
    print(result.stderr, end="")
    observed = sum(line.startswith(("PASS ", "FAIL ")) for line in result.stdout.splitlines())
    if observed != len(cases):
        print(f"Expected {len(cases)} test results, got {observed}")
        raise SystemExit(1)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
