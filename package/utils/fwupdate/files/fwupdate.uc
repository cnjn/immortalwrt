#!/usr/bin/ucode
// SPDX-License-Identifier: GPL-2.0-only
//
// Look for a newer firmware among the GitHub releases of this build and
// install it.
//
// A release is recognised by its image, whose name ends in the revision the
// build reports in DISTRIB_REVISION, for example sr1010-owrt-r38035-d301503f3e.bin.
// The number after the "r" counts the commits of the tree, so a larger number
// is a newer firmware; the tag and the title of the release are free text.
//
//   fwupdate status              what is known, as JSON
//   fwupdate check               ask GitHub for the latest release
//   fwupdate download            fetch and verify the image of that release
//   fwupdate cancel              stop a running download
//   fwupdate verify              check the downloaded image before installing
//   fwupdate upgrade [-n]        install it (-n: do not keep the settings)
//   fwupdate ignore [revision]   do not announce this release (none: undo)
//   fwupdate daemon              check once a day (run by procd)

'use strict';

let fs = require('fs');
let uci = require('uci');
let math = require('math');

const STATE_DIR = '/tmp/fwupdate';
const CHECK_FILE = STATE_DIR + '/check.json';
const DOWNLOAD_FILE = STATE_DIR + '/download.json';
const IMAGE = STATE_DIR + '/firmware.bin';
const DEFAULT_REPO = 'cnjn/immortalwrt';
const CHECK_INTERVAL = 86400;
const RETRY_INTERVAL = 3600;

function config() {
	let c = uci.cursor();
	let s = c.get_all('fwupdate', 'main') || {};

	return {
		auto_check: s.auto_check != '0',
		repo: s.repo || DEFAULT_REPO,
		api_url: s.api_url,
		mirror: s.mirror,
		proxy: s.proxy,
		ignore: s.ignore
	};
}

function parse_revision(rev) {
	let m = match(rev, /^r([0-9]+)(\+([0-9]+))?-([0-9a-f]+)$/);

	if (!m)
		return null;

	return { revision: rev, count: +m[1] + +(m[3] ?? 0), hash: m[4] };
}

function read_json(path) {
	let data = fs.readfile(path);

	if (data == null)
		return null;

	try {
		return json(data);
	}
	catch (e) {
		return null;
	}
}

// Write through a temporary file, so that a reader never sees half of it.
function write_json(path, data) {
	fs.mkdir(STATE_DIR);
	fs.writefile(path + '.tmp', sprintf('%J\n', data));
	fs.rename(path + '.tmp', path);
}

function shell_quote(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

function running_firmware() {
	let fw = {};

	for (let line in split(fs.readfile('/etc/openwrt_release') || '', '\n')) {
		let m = match(line, /^(DISTRIB_[A-Z]+)='(.*)'$/);

		if (m)
			fw[m[1]] = m[2];
	}

	return {
		description: fw.DISTRIB_DESCRIPTION,
		revision: fw.DISTRIB_REVISION,
		parsed: parse_revision(fw.DISTRIB_REVISION)
	};
}

// curl with the configured proxy; the last line it complains with is the error.
function curl(cfg, args) {
	let errfile = STATE_DIR + '/curl.err';
	let argv = [ 'curl', '-fsS', '-L', '--stderr', errfile, '-A', 'fwupdate' ];

	if (cfg.proxy)
		push(argv, '-x', cfg.proxy);

	push(argv, ...args);
	fs.mkdir(STATE_DIR);

	let rc = system(argv);
	let err = null;

	if (rc != 0) {
		let lines = filter(split(trim(fs.readfile(errfile) || ''), '\n'), length);

		err = length(lines) ? lines[-1] : sprintf('curl exited with code %d', rc);
	}

	fs.unlink(errfile);

	return err;
}

function release_image(rel) {
	for (let a in rel.assets || []) {
		let m = match(a.name, /-(r[0-9]+(\+[0-9]+)?-[0-9a-f]+)\.bin$/);

		if (!m)
			continue;

		let sha256 = match(a.digest || '', /^sha256:([0-9a-f]{64})$/);

		return {
			name: a.name,
			url: a.browser_download_url,
			size: a.size,
			sha256: sha256 ? sha256[1] : null,
			parsed: parse_revision(m[1])
		};
	}

	return null;
}

function check() {
	let cfg = config();
	let prev = read_json(CHECK_FILE) || {};
	let url = cfg.api_url || sprintf('https://api.github.com/repos/%s/releases/latest', cfg.repo);
	let out = STATE_DIR + '/release.json';
	let err = curl(cfg, [ '--connect-timeout', '10', '--max-time', '20',
		'-H', 'Accept: application/vnd.github+json', '-o', out, url ]);
	let rel = err ? null : read_json(out);

	fs.unlink(out);

	if (!err && type(rel) != 'object')
		err = 'GitHub sent something that is not a release';

	let result = { time: time(), error: err, release: prev.release };

	if (!err)
		result.release = {
			tag: rel.tag_name,
			name: rel.name || rel.tag_name,
			url: rel.html_url,
			published: rel.published_at,
			notes: rel.body,
			image: release_image(rel)
		};

	write_json(CHECK_FILE, result);

	return result;
}

function process_alive(pid) {
	return pid && fs.access(sprintf('/proc/%d', pid));
}

function download_state() {
	let st = read_json(DOWNLOAD_FILE);

	if (!st)
		return { state: 'none' };

	if (st.state == 'downloading' || st.state == 'verifying') {
		if (!process_alive(st.pid))
			return { ...st, state: 'failed', error: 'The download stopped' };

		st.received = fs.stat(IMAGE + '.part')?.size ?? 0;
	}

	if (st.state == 'ready' && !fs.access(IMAGE))
		return { state: 'none' };

	return st;
}

// What the overview and the update page show.
function status() {
	let cfg = config();
	let fw = running_firmware();
	let chk = read_json(CHECK_FILE);
	let img = chk?.release?.image;
	let update = 'unknown';

	if (!chk?.release)
		update = 'unchecked';
	else if (fw.parsed && img?.parsed) {
		if (img.parsed.count > fw.parsed.count)
			update = (img.parsed.revision == cfg.ignore) ? 'ignored' : 'available';
		else if (img.parsed.count < fw.parsed.count)
			update = 'newer';
		else
			update = (img.parsed.hash == fw.parsed.hash) ? 'current' : 'different';
	}

	return {
		firmware: fw,
		auto_check: cfg.auto_check,
		ignore: cfg.ignore,
		checked: chk?.time,
		error: chk?.error,
		release: chk?.release,
		update,
		download: download_state()
	};
}

function free_tmp_bytes() {
	let p = fs.popen('df -k /tmp 2>/dev/null', 'r');
	let out = p ? p.read('all') : '';

	p?.close();

	let m = match(out, /\n\S+\s+[0-9]+\s+[0-9]+\s+([0-9]+)/);

	return m ? +m[1] * 1024 : null;
}

function sha256(path) {
	let p = fs.popen('sha256sum ' + shell_quote(path), 'r');
	let out = p ? p.read('all') : '';

	p?.close();

	return match(out, /^[0-9a-f]{64}/)?.[0];
}

function download() {
	let cfg = config();
	let img = read_json(CHECK_FILE)?.release?.image;
	let cur = download_state();

	if (cur.state == 'downloading' || cur.state == 'verifying')
		return 'A download is already running';

	if (!img?.url || !img?.sha256)
		return 'The latest release has no image with a revision and a SHA-256 digest';

	if (cur.state == 'ready' && cur.sha256 == img.sha256)
		return null;

	fs.unlink(IMAGE);
	fs.unlink(IMAGE + '.part');

	// sysupgrade needs room in RAM next to the image as well.
	let free = free_tmp_bytes();

	if (free != null && free < img.size + 16 * 1024 * 1024) {
		let err = sprintf('Not enough free memory: the image needs %d MiB, %d MiB are free',
			img.size / 1048576 + 16, free / 1048576);

		write_json(DOWNLOAD_FILE, { state: 'failed', error: err });

		return err;
	}

	// readfile runs in this process, so /proc/self is the download itself.
	let st = {
		state: 'downloading',
		pid: +split(fs.readfile('/proc/self/stat') || '', ' ')[0] || null,
		revision: img.parsed.revision,
		name: img.name,
		size: img.size,
		sha256: img.sha256,
		started: time()
	};

	write_json(DOWNLOAD_FILE, st);

	let err = curl(cfg, [ '--connect-timeout', '15', '--retry', '2',
		'--speed-limit', '1024', '--speed-time', '60',
		'-o', IMAGE + '.part', (cfg.mirror || '') + img.url ]);

	if (!err) {
		st.state = 'verifying';
		write_json(DOWNLOAD_FILE, st);

		if (sha256(IMAGE + '.part') != img.sha256)
			err = 'The SHA-256 of the downloaded image does not match the release';
	}

	if (err) {
		fs.unlink(IMAGE + '.part');
		write_json(DOWNLOAD_FILE, { ...st, state: 'failed', pid: null, error: err });

		return err;
	}

	fs.rename(IMAGE + '.part', IMAGE);
	write_json(DOWNLOAD_FILE, { ...st, state: 'ready', pid: null, finished: time() });

	return null;
}

function cancel() {
	let st = download_state();

	if (st.state != 'downloading' && st.state != 'verifying')
		return 'No download is running';

	// The rpcd plugin starts the download in a session of its own: stop curl too.
	if (system([ 'kill', '-TERM', '-' + st.pid ]) != 0)
		system([ 'kill', '-TERM', '' + st.pid ]);

	fs.unlink(IMAGE + '.part');
	write_json(DOWNLOAD_FILE, { state: 'none' });

	return null;
}

// The image must still be the one the release names, and sysupgrade must accept it.
function verify() {
	let st = download_state();

	if (st.state != 'ready')
		return 'No downloaded image';

	if (sha256(IMAGE) != st.sha256)
		return 'The downloaded image has changed since it was verified';

	if (system([ '/sbin/sysupgrade', '--test', IMAGE ]) != 0)
		return 'sysupgrade does not accept the image';

	return null;
}

function upgrade(keep) {
	let err = verify();

	if (err)
		return err;

	let argv = [ '/sbin/sysupgrade' ];

	if (!keep)
		push(argv, '-n');

	push(argv, IMAGE);

	return (system(argv) == 0) ? null : 'sysupgrade failed';
}

function ignore(rev) {
	let c = uci.cursor();

	if (rev)
		c.set('fwupdate', 'main', 'ignore', rev);
	else
		c.delete('fwupdate', 'main', 'ignore');

	c.commit('fwupdate');

	return null;
}

// Check a few minutes after the start and then once a day, at a time that
// differs from router to router. A check that failed, for example before the
// WAN was up, is repeated after an hour.
function daemon() {
	math.srand(time());
	sleep((300 + math.rand() % 600) * 1000);

	while (true) {
		let last = read_json(CHECK_FILE);
		let due = (last?.time ?? 0) + (last?.error ? RETRY_INTERVAL : CHECK_INTERVAL) - time();

		if (due > 0) {
			sleep((due + math.rand() % 600) * 1000);
			continue;
		}

		if (config().auto_check)
			check();
		else
			sleep(CHECK_INTERVAL * 1000);
	}
}

function result(err) {
	if (err) {
		warn(err, '\n');
		exit(1);
	}

	exit(0);
}

switch (ARGV[0]) {
case 'status':
	print(sprintf('%J\n', status()));
	break;

case 'check': {
	let res = check();

	print(sprintf('%J\n', status()));
	exit(res.error ? 1 : 0);
}

case 'download':
	result(download());

case 'cancel':
	result(cancel());

case 'verify':
	result(verify());

case 'upgrade':
	result(upgrade(ARGV[1] != '-n'));

case 'ignore':
	result(ignore(ARGV[1]));

case 'daemon':
	daemon();
	break;

default:
	warn('usage: fwupdate status|check|download|cancel|verify|upgrade [-n]|ignore [revision]|daemon\n');
	exit(2);
}
