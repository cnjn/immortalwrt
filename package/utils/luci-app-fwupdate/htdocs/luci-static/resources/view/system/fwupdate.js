'use strict';
'require view';
'require dom';
'require form';
'require rpc';
'require uci';
'require ui';

var callStatus = rpc.declare({
	object: 'luci.fwupdate',
	method: 'status',
	expect: { '': {} }
});

var callCheck = rpc.declare({
	object: 'luci.fwupdate',
	method: 'check',
	expect: { '': {} }
});

var callDownload = rpc.declare({
	object: 'luci.fwupdate',
	method: 'download',
	expect: { '': {} }
});

var callCancel = rpc.declare({
	object: 'luci.fwupdate',
	method: 'cancel',
	expect: { '': {} }
});

var callUpgrade = rpc.declare({
	object: 'luci.fwupdate',
	method: 'upgrade',
	params: [ 'keep' ],
	expect: { '': {} }
});

var callIgnore = rpc.declare({
	object: 'luci.fwupdate',
	method: 'ignore',
	params: [ 'revision' ],
	expect: { '': {} }
});

function formatTime(t) {
	var d = (typeof(t) == 'number') ? new Date(t * 1000) : new Date(t);

	return isNaN(d) ? '–' : d.toLocaleString();
}

function updateText(st) {
	var img = st.release && st.release.image;

	switch (st.update) {
	case 'available':
		return _('A newer firmware is available: %s.').format(img.parsed.revision);
	case 'ignored':
		return _('A newer firmware is available: %s. You chose not to be reminded of it.').format(img.parsed.revision);
	case 'current':
		return _('The router runs the latest firmware.');
	case 'newer':
		return _('The router runs a firmware newer than the latest release.');
	case 'different':
		return _('The router runs a different build of the same revision as the latest release.');
	case 'unchecked':
		return _('No check has been made yet.');
	default:
		if (!img)
			return _('The latest release has no image named after a revision, so it cannot be compared with this firmware.');

		return _('The revision of this firmware is unknown, so it cannot be compared with the latest release.');
	}
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			uci.load('fwupdate')
		]);
	},

	refresh: function(st) {
		if (st)
			return Promise.resolve(dom.content(this.statusNode, this.renderStatus(st)));

		return callStatus().then(L.bind(function(st) {
			dom.content(this.statusNode, this.renderStatus(st));
			return st;
		}, this));
	},

	handleCheck: function() {
		return callCheck().then(L.bind(this.refresh, this)).catch(function(err) {
			ui.addNotification(null, E('p', _('The check failed: %s').format(err.message || err)), 'danger');
		});
	},

	handleIgnore: function(revision) {
		return callIgnore(revision || '').then(L.bind(function() {
			return this.refresh();
		}, this));
	},

	handleInstall: function(st) {
		var img = st.release.image;
		var keep = E('input', { 'type': 'checkbox', 'checked': true });

		ui.showModal(_('Install firmware %s').format(img.parsed.revision), [
			E('p', _('The router downloads %s (%1024.2mB) from GitHub, checks its SHA-256 against the release and installs it into the other firmware slot. It then restarts into the new firmware. Do not switch the router off while it does this.').format(img.name, img.size)),
			E('p', E('label', {}, [ keep, ' ', _('Keep settings and retain the current configuration') ])),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-action important',
					'click': ui.createHandlerFn(this, function() { return this.doDownload(keep.checked); })
				}, _('Download and install'))
			])
		]);
	},

	doDownload: function(keep) {
		var progress = E('p', { 'class': 'spinning' }, _('Starting the download…'));
		var stopped = false;

		ui.showModal(_('Downloading firmware…'), [
			progress,
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, function() {
						stopped = true;
						return callCancel().then(ui.hideModal).then(L.bind(this.refresh, this, null));
					})
				}, _('Cancel'))
			])
		]);

		var poll = L.bind(function(st) {
			var dl = st.download || {};

			if (stopped)
				return;

			if (dl.state == 'ready')
				return this.doUpgrade(keep);

			if (dl.state == 'failed' || dl.state == 'none') {
				ui.hideModal();
				ui.addNotification(null, E('p', _('The download failed: %s').format(dl.error || _('unknown error'))), 'danger');
				return this.refresh(st);
			}

			dom.content(progress, (dl.state == 'verifying')
				? _('Checking the SHA-256…')
				: _('Downloaded %1024.2mB of %1024.2mB').format(dl.received || 0, dl.size || 0));

			return new Promise(function(resolve) { window.setTimeout(resolve, 2000); })
				.then(callStatus).then(poll);
		}, this);

		return callDownload().then(poll).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', _('The download failed: %s').format(err.message || err)), 'danger');
		});
	},

	doUpgrade: function(keep) {
		ui.showModal(_('Installing firmware…'), [
			E('p', { 'class': 'spinning' }, _('Checking the image…'))
		]);

		return callUpgrade(keep).then(function(res) {
			if (res.result !== 0) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('The firmware was not installed: %s').format(res.message || _('unknown error'))), 'danger');
				return;
			}

			ui.showModal(_('Installing firmware…'), [
				E('p', { 'class': 'spinning' }, _('The system is flashing now. DO NOT POWER OFF THE DEVICE! Wait a few minutes before you try to reconnect. It might be necessary to renew the address of your computer to reach the device again, depending on your settings.'))
			]);

			if (keep)
				ui.awaitReconnect(window.location.host);
			else
				ui.awaitReconnect('192.168.5.1', 'immortalwrt.lan');
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', _('The firmware was not installed: %s').format(err.message || err)), 'danger');
		});
	},

	renderStatus: function(st) {
		var rel = st.release;
		var img = rel && rel.image;
		var fw = st.firmware || {};
		var rows = [
			[ _('Running firmware'), fw.description || fw.revision || '–' ],
			[ _('Last check'), st.checked ? formatTime(st.checked) : _('never') ]
		];

		if (st.error)
			rows.push([ _('Check error'), st.error ]);

		if (rel) {
			rows.push([ _('Latest release'), E('a', { 'href': rel.url, 'target': '_blank', 'rel': 'noreferrer' }, rel.name || rel.tag) ]);
			rows.push([ _('Published'), formatTime(rel.published) ]);

			if (img)
				rows.push([ _('Image'), '%s (%1024.2mB)'.format(img.name, img.size) ]);
		}

		var actions = [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleCheck')
			}, _('Check now'))
		];

		if (st.update == 'available' || st.update == 'ignored')
			actions.push(' ', E('button', {
				'class': 'btn cbi-button cbi-button-positive important',
				'click': ui.createHandlerFn(this, 'handleInstall', st)
			}, _('Download and install…')));

		if (st.update == 'available')
			actions.push(' ', E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(this, 'handleIgnore', img.parsed.revision)
			}, _('Do not remind me of this version')));
		else if (st.update == 'ignored')
			actions.push(' ', E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(this, 'handleIgnore', null)
			}, _('Remind me again')));

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Status')),
			E('p', { 'class': (st.update == 'available') ? 'alert-message notice' : '' }, updateText(st)),
			E('table', { 'class': 'table' }, rows.map(function(r) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, r[0]),
					E('td', { 'class': 'td left' }, r[1])
				]);
			})),
			(rel && rel.notes) ? E('details', {}, [
				E('summary', _('Release notes')),
				E('pre', { 'style': 'white-space: pre-wrap' }, rel.notes)
			]) : '',
			E('div', { 'class': 'cbi-page-actions' }, actions)
		]);
	},

	render: function(data) {
		var m, s, o;

		m = new form.Map('fwupdate', _('Firmware Update'),
			_('The router looks for a newer firmware among the releases on GitHub and announces it on the overview page. Nothing is installed without your confirmation.'));

		s = m.section(form.NamedSection, 'main', 'fwupdate', _('Settings'));

		o = s.option(form.Flag, 'auto_check', _('Check automatically'),
			_('Check once a day. When this is off, the router only checks when you press "Check now".'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'repo', _('GitHub repository'));
		o.placeholder = 'cnjn/immortalwrt';

		o = s.option(form.Value, 'mirror', _('Download mirror'),
			_('Put in front of the image URL, for a GitHub mirror that is reachable from here. The image is still checked against the SHA-256 that GitHub publishes.'));
		o.placeholder = 'https://ghfast.top/';

		o = s.option(form.Value, 'proxy', _('Proxy'),
			_('HTTP proxy for the check and the download.'));
		o.placeholder = 'http://192.168.5.2:7890';

		this.statusNode = E('div', {}, this.renderStatus(data[0]));

		return m.render().then(L.bind(function(node) {
			node.insertBefore(this.statusNode, node.querySelector('.cbi-section'));
			return node;
		}, this));
	}
});
