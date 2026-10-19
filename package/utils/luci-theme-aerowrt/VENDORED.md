# Vendored: luci-theme-aerowrt

An ASUSWRT-inspired LuCI theme, taken from a third-party project and adapted for this tree.

- Upstream: https://github.com/stevenke1981/openwrt-asus-theme (Apache-2.0, see `LICENSE`)
- Commit: `315b674ef1f7757f79d0f20ca756cf7774cb0041` (2026-08-02, "feat: add AeroWRT network map and zh-Hant i18n")
- Taken: 2026-10-10

## What was taken

Only the theme: the ucode templates, `htdocs/luci-static/aerowrt`, the first-boot UCI
script, `po/zh_Hant`, `Makefile`, `LICENSE` and `README.md`.

Not taken:

- `app/luci-app-aerowrt-map`: its page shows demo data (WAN address, SSIDs and clients are
  made up; only the host name is live), which would mislead on a real router.
- `luasrc/`: Lua templates for the compatibility mode, this image has no Lua runtime.
- The static preview page, the Windows scripts and the `.agent` directory.

All scripts, templates and makefiles were read before inclusion. They make no network
requests, use no `eval` and load no external resources; the only browser storage is the
`sessionStorage` flag for the narrow-screen drawer.

## Changes against upstream

1. `root/etc/uci-defaults/30_luci-theme-aerowrt` only registers the theme (it shows up under
   System > System > Language and Style). Upstream also set `luci.main.mediaurlbase`, which
   made it the active theme on every flash; this image keeps Bootstrap as its default.
2. `ucode/template/themes/aerowrt/header.ut` gets the `#indicators` and `#tabmenu`
   containers. LuCI's `ui.showIndicator()` silently does nothing without `#indicators`, so
   the "unsaved changes" and "refreshing" indicators were missing.
3. `htdocs/luci-static/aerowrt/menu-aerowrt.js` renders the tabs of menu entries below the
   third level (for example Status > Realtime Graphs); ported from `menu-bootstrap.js`.
4. `htdocs/luci-static/aerowrt/cascade.css` gets styles for both containers at the end.
5. `htdocs/luci-static/aerowrt/network-map.js` is removed (used by the preview page only).

## Status

Built against the LuCI in this tree (feed commit `ed7692cb`). The template variables and the
menu API it uses were checked against `luci-theme-bootstrap` and `luci-base` of that revision.
Not yet looked at in a browser on the device.
