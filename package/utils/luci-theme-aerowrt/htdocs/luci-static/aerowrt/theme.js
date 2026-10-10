/*
 * AeroWRT theme for LuCI - theme behaviour
 *
 * Copyright 2026 AeroWRT contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Dependency-free UI behaviour for the theme chrome only:
 *   - off-canvas sidebar toggle on narrow screens
 *   - click-outside (scrim) and Escape to close
 *   - remember the open/closed preference per viewport
 *
 * It never touches LuCI core widgets; everything is guarded so the script
 * is safe both inside LuCI and in the static preview page.
 */
(function () {
	"use strict";

	var STORAGE_KEY = "aerowrt.navOpen";
	var BREAKPOINT = 992;

	function $(id) { return document.getElementById(id); }

	function isNarrow() {
		return window.matchMedia("(max-width: " + BREAKPOINT + "px)").matches;
	}

	function prefersReducedMotion() {
		return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
	}

	function init() {
		var app = document.querySelector(".awrt-app");
		var sidebar = $("awrt-sidebar");
		var toggle = $("awrt-menu-toggle");
		var scrim = $("awrt-scrim");

		if (!app || !sidebar) { return; }

		function setOpen(open) {
			app.classList.toggle("awrt-nav-open", open);
			if (toggle) { toggle.setAttribute("aria-expanded", open ? "true" : "false"); }
			if (scrim) {
				if (open) {
					scrim.hidden = false;
					// next frame so the opacity transition runs (unless reduced motion)
					if (prefersReducedMotion()) {
						scrim.classList.add("is-visible");
					} else {
						window.requestAnimationFrame(function () {
							scrim.classList.add("is-visible");
						});
					}
				} else {
					scrim.classList.remove("is-visible");
					scrim.hidden = true;
				}
			}
			try { sessionStorage.setItem(STORAGE_KEY, open ? "1" : "0"); } catch (e) { /* ignore */ }
		}

		function isOpen() { return app.classList.contains("awrt-nav-open"); }

		if (toggle) {
			toggle.addEventListener("click", function () { setOpen(!isOpen()); });
		}

		if (scrim) {
			scrim.addEventListener("click", function () { setOpen(false); });
		}

		document.addEventListener("keydown", function (e) {
			if (e.key === "Escape" && isOpen() && isNarrow()) { setOpen(false); }
		});

		// Close the drawer automatically when navigating to a new page on mobile.
		var nav = $("awrt-nav");
		if (nav) {
			nav.addEventListener("click", function (e) {
				var t = e.target;
				if (t && t.closest && t.closest("a") && isNarrow()) { setOpen(false); }
			});
		}

		// Reset to a sane state when crossing the breakpoint.
		var mq = window.matchMedia("(max-width: " + BREAKPOINT + "px)");
		var onChange = function () {
			if (!isNarrow()) { setOpen(false); }
		};
		if (mq.addEventListener) { mq.addEventListener("change", onChange); }
		else if (mq.addListener) { mq.addListener(onChange); }

		// Restore a remembered open state (mobile only).
		if (isNarrow()) {
			var saved = null;
			try { saved = sessionStorage.getItem(STORAGE_KEY); } catch (e) { /* ignore */ }
			if (saved === "1") { setOpen(true); }
		}
	}

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", init);
	} else {
		init();
	}
})();
