# AeroWRT LuCI Theme

AeroWRT is an ASUSWRT-inspired OpenWrt LuCI theme package. It keeps the familiar router workflow—dark navy navigation, blue state accents, light information cards and a compact network summary—without bundling ASUS trademarks, official artwork, remote fonts or external assets.

## What is included

- `Makefile`: OpenWrt feed package definition for `luci-theme-aerowrt`.
- `luasrc/view/themes/aerowrt/`: Lua compatibility-mode header and footer templates.
- `ucode/template/themes/aerowrt/`: native LuCI 23.05+/24.10 header, footer and login templates.
- `htdocs/luci-static/aerowrt/`: local CSS, responsive rules, JavaScript and an inline SVG favicon.
- `root/etc/uci-defaults/30_luci-theme-aerowrt`: registers AeroWRT and selects it as the active LuCI media URL on first install.
- `app/luci-app-aerowrt-map/`: optional companion LuCI app that adds an ASUSWRT-inspired **Network Map** page under Status, with a safe `system.board` identity lookup and deterministic demo topology fallback.
- `po/zh_Hant/aerowrt.po`: Traditional Chinese translations for the theme chrome. LuCI's `luci.mk` produces `luci-i18n-aerowrt-zh-tw` from this catalog.
- `static-preview/index.html`: a local visual preview that reuses the exact shipped assets and sample router data.
- `scripts/validate.ps1` and `scripts/build-package.ps1`: Windows-friendly checks and source archive generation.

## Quick start

From an OpenWrt buildroot with the LuCI feed installed:

```sh
cp -a . /path/to/openwrt/package/luci-theme-aerowrt
make package/luci-theme-aerowrt/compile V=s
cp -a app/luci-app-aerowrt-map /path/to/openwrt/package/luci-app-aerowrt-map
make package/luci-app-aerowrt-map/compile V=s
```

The resulting theme and optional map-app packages can be copied to the router and installed with `opkg`; exact filenames follow the selected OpenWrt buildroot revision. The LuCI feed also emits `luci-i18n-aerowrt-zh-tw` and `luci-i18n-aerowrt-map-zh-tw` from the bundled `po/zh_Hant` catalogs. See [docs/INSTALL.md](docs/INSTALL.md) for the complete install and rollback procedure.

On Windows, run:

```powershell
.\scripts\validate.ps1
.\scripts\build-package.ps1
```

The Windows build helper always creates a source archive in `dist/`; it only invokes OpenWrt `make` builds when `-OpenWrtRoot` is supplied and a compatible buildroot is available. With a buildroot, it copies and compiles both the theme and the companion map app.

## Local visual preview

Open `static-preview/index.html` directly in a browser, or serve the project directory with any local static server. The preview uses the package's real `cascade.css`, `mobile.css`, `network-map.css`, `network-map.js` and `theme.js` files. It exercises the navigation drawer, ASUSWRT-style Internet → router → wireless topology, band filtering, refresh affordance, cards, badges, forms, tables, alerts, loading and progress styles. The map is intentionally sample-data only: a green preview is not proof of LuCI or router end-to-end compatibility.

## Compatibility

- Target: OpenWrt 23.05+ with LuCI `luci-base`.
- Architecture: `all`; no compiled binaries.
- No CDN, network image, remote font or third-party runtime dependency.
- The templates follow LuCI's classic Lua and current ucode theme contracts and do not modify LuCI core JavaScript or CBI widgets.
- The companion map app adds only the `admin/status/aerowrt-map` view and a read-only `system.board` ACL; WAN, wireless and client metrics remain explicitly labelled deterministic UI sample data until a real backend is added.
- Exact rendering can still vary with the installed LuCI revision, enabled extensions, locale and browser. Test the package on a disposable router or keep a second theme available for rollback.

## License

Apache-2.0. See [LICENSE](LICENSE).
