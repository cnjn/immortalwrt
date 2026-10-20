'use strict';
'require baseclass';
'require dom';
'require rpc';
'require ui';

var callStatus = rpc.declare({
	object: 'luci.fwupdate',
	method: 'status',
	expect: { '': {} }
});

var callIgnore = rpc.declare({
	object: 'luci.fwupdate',
	method: 'ignore',
	params: [ 'revision' ],
	expect: { '': {} }
});

/* The overview polls every few seconds; the check result changes once a day at most. */
var cache = null, cacheTime = 0;

return baseclass.extend({
	title: _('Firmware Update'),

	load: function() {
		if (cache && Date.now() - cacheTime < 60000)
			return Promise.resolve(cache);

		return callStatus().then(function(st) {
			cache = st;
			cacheTime = Date.now();
			return st;
		});
	},

	handleIgnore: function(revision, ev) {
		var section = dom.parent(ev.currentTarget, '.cbi-section');

		return callIgnore(revision).then(function() {
			cache = null;

			if (section)
				section.style.display = 'none';
		});
	},

	/* Only shown while a newer firmware waits; otherwise the overview has no section for it. */
	render: function(st) {
		if (!st || st.update != 'available')
			return null;

		var rel = st.release, img = rel.image;

		return E('div', {}, [
			E('p', { 'class': 'alert-message notice' },
				_('A new firmware has been released: %s (%s, %s). This router runs %s.').format(
					rel.name || rel.tag, img.parsed.revision,
					new Date(rel.published).toLocaleDateString(),
					st.firmware.revision || '?')),
			rel.notes ? E('details', {}, [
				E('summary', _('Release notes')),
				E('pre', { 'style': 'white-space: pre-wrap' }, rel.notes)
			]) : '',
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, 'handleIgnore', img.parsed.revision)
				}, _('Do not remind me of this version')),
				' ',
				E('a', {
					'class': 'btn cbi-button cbi-button-positive important',
					'href': L.url('admin/system/fwupdate')
				}, _('View and install'))
			])
		]);
	}
});
