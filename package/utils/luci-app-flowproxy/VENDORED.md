# Vendored: luci-app-flowproxy

FlowProxy marks LAN TCP/UDP traffic with nftables and policy-routes it to a proxy host on
the LAN (a "bypass gateway"), optionally pointing dnsmasq at that host's DNS port. It is a
LuCI app with a procd service and no binary of its own; it is off until enabled and given
the proxy server address.

- Upstream: https://github.com/0x5826/openwrt-packages-extras, `luci-app-flowproxy`
  (version 1.0.3; the repository has no license file)
- Commit: `d693982` (2026-10-16)
- Taken: 2026-10-24

## Changes against upstream

None.
