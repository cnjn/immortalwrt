# Vendored: luci-app-lxc

LuCI's LXC container manager, taken from the luci feed so that it can be changed in this tree.

- Upstream: https://github.com/immortalwrt/luci, `applications/luci-app-lxc` (Apache-2.0)
- Commit: `ed7692cb08a953e2e503287e0337c8b548cf4ba5` (the luci feed revision of this tree)
- Taken: 2026-10-19

The package shadows the feed one: run `./scripts/feeds uninstall luci-app-lxc` once after
`./scripts/feeds install -a`, otherwise the feed copy is linked into `package/feeds/luci` too.

## Changes against upstream

- Settings tab: **Container Storage Path** (`lxc.lxc.lxcpath`, default `/srv/lxc`). On
  "Save & Apply", `/usr/libexec/luci-lxc-path` (registered through
  `/usr/share/ucitrack/luci-app-lxc.json`) writes it to `lxc.lxcpath` in `/etc/lxc/lxc.conf`,
  which lxc-create, lxc-start, rpcd-mod-lxc and this page read. It refuses relative paths,
  odd characters and file systems without Unix permissions (FAT, exFAT, NTFS, ...), logging
  the reason, and creates the directory. Existing containers are not moved. It runs only on
  apply, not at boot, so a USB disk that is mounted late is never shadowed by a directory
  created on the overlay.
- `80_luci-lxc-path` (uci-defaults): fills the option from the current `lxc.conf` and reloads
  ucitrack.
- Makefile: includes `$(TOPDIR)/feeds/luci/luci.mk`.
- zh_Hans translations for the new strings.
