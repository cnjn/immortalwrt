#!/usr/bin/ucode
'use strict';
import * as fs from 'fs';
import { cursor } from 'uci';

const MAX_SIZE = 1048576;
function check(ok, message) { if (!ok) die(message); }
function save(path, data) {
    check(fs.writefile(path, data) != null, 'Unable to write backup staging file');
    check(fs.chmod(path, 0o600), 'Unable to secure backup staging file');
}
function read_asset(path) {
    let info = fs.stat(path);
    check(info && info.type == 'file' && info.size <= MAX_SIZE, 'Missing or oversized list file: ' + path);
    let content = fs.readfile(path);
    check(content != null && index(content, '\x00') < 0, 'Unreadable list file: ' + path);
    return content;
}
function ipv4(value) {
    if (type(value) != 'string' || !match(value, /^\d+\.\d+\.\d+\.\d+$/)) return false;
    for (let part in split(value, '.')) if (int(part) > 255 || (length(part) > 1 && substr(part, 0, 1) == '0')) return false;
    return true;
}
function bounded(options, name, min, max) {
    let value = options[name];
    if (value == null) return;
    check(type(value) == 'string' && match(value, /^\d+$/) && int(value) >= min && int(value) <= max,
        'Invalid numeric setting: ' + name);
}
function validate_elements(content, element_type) {
    for (let line in split(content, '\n')) {
        line = trim(split(line, '#')[0]);
        if (!line) continue;
        for (let token in split(line, /[\t ,]+/)) {
            if (!token) continue;
            let pattern = element_type == 'ipv4_addr' ? /^[0-9.\/-]+$/ :
                element_type == 'ether_addr' ? /^[0-9a-fA-F:-]+$/ : /^[A-Za-z0-9_-]+$/;
            check(match(token, pattern), 'Invalid or unsafe address/port list element');
        }
    }
}
function validate_expression(value) {
    check(index(value, ';') < 0 && index(value, '#') < 0, 'Rule expressions must not contain statement separators');
    let depth = 0;
    for (let i = 0; i < length(value); i++) {
        let ch = substr(value, i, 1);
        if (ch == '{') depth++;
        if (ch == '}') depth--;
        check(depth >= 0, 'Unbalanced braces in rule expression');
    }
    check(depth == 0, 'Unbalanced braces in rule expression');
}
function validate_global(options) {
    for (let flag in ['enabled', 'tcp_enabled', 'udp_enabled', 'dns_proxy_enabled', 'domain_direct_enabled',
        'apple_ip_direct_enabled', 'microsoft_ip_direct_enabled', 'device_fallback_enabled', 'node_fallback_enabled'])
        check(options[flag] == null || options[flag] == '0' || options[flag] == '1', 'Invalid switch: ' + flag);
    if (options.enabled == '1') check(ipv4(options.proxy_server_ip_addr), 'A valid proxy IPv4 address is required');
    if (options.direct_domain_dns != null) check(ipv4(options.direct_domain_dns), 'Invalid direct DNS IPv4 address');
    if (options.interface != null) check(match(options.interface, /^[A-Za-z0-9_.:-]{1,15}$/), 'Invalid interface name');
    bounded(options, 'proxy_server_dns_port', 1, 65535);
    bounded(options, 'health_socks_port', 1, 65535);
    bounded(options, 'health_interval', 3, 300);
    bounded(options, 'health_timeout', 1, 30);
    bounded(options, 'health_failures', 1, 20);
    bounded(options, 'health_successes', 1, 20);
    bounded(options, 'routing_table', 1, 4294967295);
    check(!(options.routing_table in ['253', '254', '255']), 'Reserved routing table cannot be used by FlowProxy');
    bounded(options, 'rule_priority', 0, 4294967295);
    if (options.traffic_mark != null) check(match(options.traffic_mark, /^0x[0-9a-fA-F]{1,8}$/) ||
        (match(options.traffic_mark, /^[0-9]{1,10}$/) && int(options.traffic_mark) <= 4294967295), 'Invalid traffic mark');
    if (options.log_level != null) check(options.log_level in ['debug', 'info', 'warn', 'error'], 'Invalid log level');
    for (let name in ['direct_domain_suffix', 'direct_domain_keyword', 'node_probe_url']) {
        let values = options[name];
        if (values == null) continue;
        if (type(values) == 'string') values = [values];
        check(type(values) == 'array' && length(values) <= (name == 'node_probe_url' ? 5 : 1024), 'Too many values: ' + name);
        for (let value in values) {
            if (name == 'node_probe_url')
                check(match(value, /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9_~:/.?&=%+,-]*)?$/) && length(value) <= 512,
                    'Probe URLs must be HTTPS URLs without credentials or whitespace');
        }
    }
}
function stage(work) {
    let raw = fs.readfile(work + '/input.json');
    check(raw && length(raw) <= MAX_SIZE, 'Backup is empty or exceeds the 1 MiB limit');
    let data = json(raw);
    check(type(data) == 'object' && data.format == 'flowproxy-backup' && data.version == 1, 'Unsupported FlowProxy backup format/version');
    check(type(data.sections) == 'array' && length(data.sections) > 0 && length(data.sections) <= 2048, 'Invalid backup section list');
    check(type(data.files) == 'object' && type(data.service_ips) == 'object', 'Missing list data');
    let names = {}, global_count = 0;
    for (let section in data.sections) {
        check(type(section) == 'object' && type(section.name) == 'string' && match(section.name, /^[A-Za-z0-9_]{1,64}$/), 'Invalid section name');
        check(!names[section.name], 'Duplicate section name'); names[section.name] = true;
        check(section.type in ['flowproxy', 'nftset', 'tcp_rule', 'udp_rule'], 'Unsupported or runtime-only section type');
        check(type(section.anonymous) == 'bool' && type(section.options) == 'object', 'Invalid section data');
        if (section.type == 'flowproxy') {
            check(section.name == 'global' && !section.anonymous && ++global_count == 1, 'Exactly one named global section is required');
            validate_global(section.options);
        }
        if (section.type == 'nftset') {
            check(!section.anonymous && !(section.name in ['fp_direct_domains', 'fp_apple_service_v4', 'fp_microsoft_service_v4']), 'Invalid or reserved set name');
            check(section.options.type in ['ipv4_addr', 'ether_addr', 'inet_service'], 'Invalid set type');
        }
        for (let key, value in section.options) {
            check(match(key, /^[A-Za-z0-9_]{1,64}$/), 'Invalid option name');
            let values = type(value) == 'array' ? value : [value];
            check(length(values) <= 65535, 'Oversized option list');
            for (let item in values)
                check(type(item) == 'string' && length(item) <= 4096 && index(item, '\x00') < 0 && !match(item, /[[:cntrl:]]/), 'Invalid option value: ' + key);
        }
        if (section.type == 'tcp_rule' || section.type == 'udp_rule') {
            check(section.options.action == null || section.options.action in ['return', 'accept', 'drop'], 'Unsupported rule action');
            check(section.options.match_type == null || section.options.match_type in ['src_mac', 'src_ip', 'dst_ip', 'src_port', 'dst_port', 'custom'], 'Unsupported match type');
            if (section.options.match_value != null) validate_expression(section.options.match_value);
        }
        if (section.type == 'nftset' && section.options.elements != null) {
            let elements = section.options.elements;
            if (type(elements) == 'string') elements = [elements];
            for (let item in elements) validate_elements(item, section.options.type);
        }
        if (section.options.file_path != null) {
            check(section.type == 'nftset' && type(data.files[section.name]) == 'string', 'A referenced list file is missing from the backup');
            check(index(data.files[section.name], '\x00') < 0 && index(data.files[section.name], '\r') < 0, 'Invalid list file');
            validate_elements(data.files[section.name], section.options.type);
        }
    }
    check(global_count == 1, 'Global configuration is missing');
    for (let key in keys(data.files)) check(names[key], 'Orphaned list file');
    for (let dir in ['config', 'final', 'delta', 'files', 'service-ips']) check(fs.mkdir(work + '/' + dir), 'Unable to prepare import directory');
    for (let vendor in ['apple', 'microsoft']) {
        let content = data.service_ips[vendor];
        check(type(content) == 'string' && length(content) > 0 && !match(content, /[^0-9.\/\n]/), 'Invalid service IP list: ' + vendor);
        save(work + '/service-ips/' + vendor + '.cidr', content);
    }
    let persistent = '/etc/flowproxy/imported/' + fs.basename(work);
    for (let target in ['config', 'final']) {
        let config_dir = work + '/' + target;
        save(config_dir + '/flowproxy', '');
        let ctx = cursor(config_dir, work + '/delta');
        check(ctx && ctx.load('flowproxy'), 'Unable to create staged UCI configuration');
        for (let section in data.sections) {
            let sid = section.anonymous ? ctx.add('flowproxy', section.type) : section.name;
            if (!section.anonymous) check(ctx.set('flowproxy', sid, section.type), 'Unable to create UCI section');
            for (let key, value in section.options) {
                if (key == 'file_path') {
                    let file = section.name + '.txt';
                    save(work + '/files/' + file, data.files[section.name]);
                    value = (target == 'config' ? work : persistent) + '/files/' + file;
                }
                check(ctx.set('flowproxy', sid, key, value), 'Unable to stage UCI option: ' + key);
            }
        }
        check(ctx.commit('flowproxy'), 'Unable to save staged UCI configuration');
    }
    return { result: true, sections: length(data.sections) };
}
function export_config() {
    // QWRT ships an older fs module without mkdtemp(). Use the BusyBox tool.
    let fd = fs.popen('umask 077; mktemp -d /tmp/flowproxy-export.XXXXXX');
    let dir = fd ? trim(fd.read('all') || '') : ''; if (fd) fd.close();
    check(match(dir, /^\/tmp\/flowproxy-export\.[A-Za-z0-9]+$/), 'Unable to create export workspace');
    let ctx = cursor(getenv('FLOWPROXY_CONFIG_DIR') || '/etc/config', dir);
    let backup = { format: 'flowproxy-backup', version: 1, exported_at: time(), sections: [], files: {}, service_ips: {} };
    try {
        check(ctx && ctx.load('flowproxy'), 'Unable to load saved FlowProxy configuration');
        ctx.foreach('flowproxy', null, function(s) {
            if (s['.type'] == 'dns_backup') return;
            let section = { name: s['.name'], type: s['.type'], anonymous: !!s['.anonymous'], options: {} };
            for (let key, value in s) if (substr(key, 0, 1) != '.') section.options[key] = value;
            if (s['.type'] == 'nftset' && s.file_path) {
                let content = read_asset(s.file_path);
                validate_elements(content, s.type || 'ipv4_addr');
                backup.files[s['.name']] = content;
            }
            push(backup.sections, section);
        });
        for (let vendor in ['apple', 'microsoft']) {
            let path = '/etc/flowproxy/service-ips/' + vendor + '.cidr';
            if (!fs.access(path)) path = '/usr/share/flowproxy/service-ips/' + vendor + '.cidr';
            backup.service_ips[vendor] = read_asset(path);
        }
        check(length(sprintf('%J', backup)) <= MAX_SIZE, 'Backup exceeds the 1 MiB limit');
    } catch (e) { fs.rmdir(dir); die('' + e); }
    fs.rmdir(dir);
    return backup;
}

try {
    if (ARGV[0] == 'export') printf('%J\n', { result: true, backup: export_config() });
    else if (ARGV[0] == 'stage' && ARGV[1] && match(ARGV[1], /^\/tmp\/flowproxy-import\.[A-Za-z0-9]+$/))
        printf('%J\n', stage(ARGV[1]));
    else if (ARGV[0] == 'result' && ARGV[1] && match(ARGV[1], /^\/tmp\/flowproxy-import\.[A-Za-z0-9]+$/)) {
        let result;
        try { result = json(fs.readfile(ARGV[1] + '/response.json') || '{}'); } catch (e) { result = {}; }
        if (type(result.result) != 'bool') result = { result: false, error: 'Configuration import did not complete' };
        if (!result.result) result.details = substr(fs.readfile(ARGV[1] + '/validation.log') || fs.readfile(ARGV[1] + '/error.log') || '', 0, 2048);
        printf('%J\n', result);
    }
    else die('Invalid configuration transfer command');
} catch (e) {
    printf('%J\n', { result: false, error: '' + e });
    exit(1);
}
