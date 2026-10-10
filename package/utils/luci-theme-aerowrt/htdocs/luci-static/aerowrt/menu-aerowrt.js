/* AeroWRT LuCI 23.05+ menu renderer. It uses LuCI's public ui.menu API. */
'use strict';
(function () {
	function renderMenu(ui, tree) {
		var nav = document.getElementById('awrt-mainmenu');
		if (!nav || !tree) return;
		var roots = ui.menu.getChildren(tree);
		var request = (window.L && L.env && L.env.requestpath) || [];
		var dispatch = (window.L && L.env && L.env.dispatchpath) || request;
		var mode = roots.filter(function (item) { return item.name === request[0]; })[0] || roots[0];
		if (!mode) return;
		ui.menu.getChildren(mode).forEach(function (section) {
			var children = ui.menu.getChildren(section);
			var sectionActive = dispatch[1] === section.name;
			var sectionUrl = children.length ? L.url(mode.name, section.name, children[0].name) : L.url(mode.name, section.name);
			var li = E('li', { 'class': 'awrt-nav-item' + (sectionActive ? ' is-active' : '') });
			li.appendChild(E('a', { 'class': 'awrt-nav-link', 'href': sectionUrl, 'aria-current': sectionActive ? 'page' : null }, [ _(section.title) ]));
			if (children.length) {
				var sub = E('ul', { 'class': 'awrt-subnav' });
				children.forEach(function (child) {
					var active = sectionActive && dispatch[2] === child.name;
					sub.appendChild(E('li', { 'class': 'awrt-subnav-item' + (active ? ' is-active' : '') }, [
						E('a', { 'class': 'awrt-subnav-link', 'href': L.url(mode.name, section.name, child.name), 'aria-current': active ? 'page' : null }, [ _(child.title) ])
					]));
				});
				li.appendChild(sub);
			}
			nav.appendChild(li);
		});
	}

	/* Added for this tree: tabs for menu entries below the third level (for example the
	 * pages of Status > Realtime Graphs). Same logic as luci-theme-bootstrap. */
	function renderTabMenu(ui, node, url, level) {
		var container = document.getElementById('tabmenu');
		var path = (window.L && L.env && L.env.dispatchpath) || [];
		var ul = E('ul', { 'class': 'tabs' });
		var activeNode = null;
		if (!container) return;
		ui.menu.getChildren(node).forEach(function (child) {
			var active = path[3 + (level || 0)] === child.name;
			ul.appendChild(E('li', { 'class': active ? 'active' : '' }, [
				E('a', { 'href': L.url(url, child.name) }, [ _(child.title) ])
			]));
			if (active) activeNode = child;
		});
		if (!ul.children.length) return;
		container.appendChild(ul);
		container.style.display = '';
		if (activeNode) renderTabMenu(ui, activeNode, url + '/' + activeNode.name, (level || 0) + 1);
	}

	function renderTabs(ui, tree) {
		var path = (window.L && L.env && L.env.dispatchpath) || [];
		var node = tree, url = '';
		if (path.length < 3) return;
		for (var i = 0; i < 3 && node; i++) {
			node = node.children && node.children[path[i]];
			url += (url ? '/' : '') + path[i];
		}
		if (node) renderTabMenu(ui, node, url);
	}

	if (window.L && L.require) {
		L.require('ui').then(function (ui) {
			ui.menu.load().then(function (tree) { renderMenu(ui, tree); renderTabs(ui, tree); });
		}).catch(function () {});
	}
}());
