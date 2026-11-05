'use strict';
'require form';
'require uci';
'require rpc';
'require poll';
'require view';
'require dom';
'require fs';
'require ui';
'require network';

var callGetStatus = rpc.declare({
    object: 'luci.flowproxy',
    method: 'get_status'
});

var callGetLogs = rpc.declare({
    object: 'luci.flowproxy',
    method: 'get_logs',
    params: ['lines']
});

var callClearLogs = rpc.declare({
    object: 'luci.flowproxy',
    method: 'clear_logs'
});

var callGenerateNftConfig = rpc.declare({
    object: 'luci.flowproxy',
    method: 'generate_nft_config'
});

var callGetRuntimeConfig = rpc.declare({
    object: 'luci.flowproxy',
    method: 'get_runtime_config'
});

var callRestartService = rpc.declare({
    object: 'luci.flowproxy',
    method: 'restart_service'
});

var callUpdateServiceIPs = rpc.declare({
    object: 'luci.flowproxy', method: 'update_service_ips'
});

var callExportConfig = rpc.declare({ object: 'luci.flowproxy', method: 'export_config' });
var callBeginImport = rpc.declare({ object: 'luci.flowproxy', method: 'begin_import' });
var callUploadChunk = rpc.declare({ object: 'luci.flowproxy', method: 'upload_import_chunk', params: ['ticket', 'index', 'data'] });
var callFinishImport = rpc.declare({ object: 'luci.flowproxy', method: 'finish_import', params: ['ticket', 'size'] });
var callGetImportStatus = rpc.declare({ object: 'luci.flowproxy', method: 'get_import_status', params: ['ticket'] });

function uploadImport(text, progress) {
    return callBeginImport().then(function(session) {
        if (!session || !session.result) throw new Error(session && session.error || _('Configuration import failed.'));
        var offset = 0, index = 0;
        function next() {
            if (offset >= text.length) return callFinishImport(session.ticket, new Blob([text]).size);
            var piece = text.slice(offset, offset + 4096);
            // Never split a UTF-16 surrogate pair across JSON/RPC requests.
            var last = piece.charCodeAt(piece.length - 1);
            if (last >= 0xd800 && last <= 0xdbff) piece = piece.slice(0, -1);
            return callUploadChunk(session.ticket, index, piece).then(function(result) {
                if (!result || !result.result) throw new Error(result && result.error || _('Configuration import failed.'));
                offset += piece.length; index++;
                progress(Math.floor(offset * 100 / text.length));
                return next();
            });
        }
        return next();
    });
}

function waitForImport(ticket, rounds) {
    return new Promise(function(resolve) { window.setTimeout(resolve, 1000); }).then(function() {
        return callGetImportStatus(ticket);
    }).then(function(result) {
        if (!result.pending) return result;
        if (rounds >= 180) throw new Error(_('Import is still running. Check the service status before retrying.'));
        return waitForImport(ticket, rounds + 1);
    });
}

return L.view.extend({
    load: function() {
        return Promise.all([
            uci.load('flowproxy').catch(function() { return {}; }),
            network.getDevices(),
            callGetStatus().catch(function() { return {}; }),
            network.getNetworks().catch(function() { return []; })
        ]);
    },

    highlightNft: function(text) {
        if (!text || text.trim() === '') return '<span style="color: #999;">' + _('(no content / table not loaded)') + '</span>';
        var rules = [
            { rex: /#(.*)/g, cls: 'comment' },
            { rex: /\b(table|chain|set|elements|type)\b/g, cls: 'keyword' },
            { rex: /\b(ip|ip6|tcp|udp|ether|meta|meta nfproto)\b/g, cls: 'proto' },
            { rex: /\b(saddr|daddr|sport|dport|mark)\b/g, cls: 'match' },
            { rex: /\b(return|accept|drop|reject|counter|set)\b/g, cls: 'action' },
            { rex: /@[\w_]+/g, cls: 'variable' },
            { rex: /\{|\}/g, cls: 'bracket' }
        ];
        var html = text.replace(/[&<>"']/g, function(m) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m];
        });
        rules.forEach(function(r) {
            html = html.replace(r.rex, function(match) {
                return '<span class="nft-' + r.cls + '">' + match + '</span>';
            });
        });
        return html;
    },
    refreshStatus: function(map, node) {
        return callGetStatus().then(L.bind(function(status) {
            if (!status) return;
            var isRunning = (status.running == 1);
            var container = node || document;
            
            var statusEl = container.querySelector('#service-status');
            if (statusEl) {
                var content = [];
                if (isRunning) {
                    var chains = [];
                    if (status.nft && status.nft.tcp) chains.push('TCP');
                    if (status.nft && status.nft.udp) chains.push('UDP');
                    var ip = status.proxy_server_ip_addr || '-';
                    content.push(E('span', { 'style': 'color: green; font-weight: bold;' }, [ _('running') ]));
                    content.push(' (' + ip + ':');
                    content.push(E('span', { 'style': 'color: #FF9800; font-weight: bold;' }, [ chains.join('+') || '-' ]));
                    content.push(') ');
                    content.push(E('button', {
                        'class': 'btn cbi-button cbi-button-apply',
                        'style': 'margin-left: 10px;',
                        'click': ui.createHandlerFn(this, 'handleRestart')
                    }, [ _('Restart') ]));
                } else {
                    content.push(E('span', { 'style': 'color: red; font-weight: bold;' }, [ _('stopped') ]));
                }
                L.dom.content(statusEl, content);
            }

            var serviceEl = container.querySelector('#service-ip-status');
            if (serviceEl) {
                var lines = [];
                ['apple', 'microsoft'].forEach(function(vendor) {
                    var info = (status.service_ips || {})[vendor] || {};
                    var label = vendor === 'apple' ? _('Apple services') : _('Microsoft 365 services');
                    var text = label + ': ' + (info.enabled ? _('Enabled') : _('Disabled')) + ', ' +
                        _('%d IPv4 ranges').format(info.count || 0);
                    if (info.last_success) text += '; ' + _('Last verified') + ': ' + new Date(info.last_success * 1000).toLocaleString();
                    else text += '; ' + (info.result === 'imported' ? _('Imported rules') : _('Bundled rules'));
                    if (info.result === 'failed') text += '; ' + _('Update failed; keeping the last valid rules');
                    lines.push(E('div', {}, text));
                });
                L.dom.content(serviceEl, lines);
            }

            var domainEl = container.querySelector('#domain-direct-status');
            if (domainEl) L.dom.content(domainEl, status.domain_dns_running ?
                _('Running; %d cached IPv4 addresses').format(status.domain_cached_ips || 0) : _('Disabled or no domain rules configured'));

            var healthEl = container.querySelector('#health-status');
            if (healthEl) {
                var health = status.health || {};
                var labels = {
                    healthy: _('Healthy'), inactive: _('FlowProxy is stopped'), disabled: _('Automatic fallback is disabled'),
                    checking_device: _('Device check is failing; waiting for the failure threshold'),
                    checking_node: _('Proxy internet check is failing; waiting for the failure threshold'),
                    paused_device: _('Device unavailable; direct routing is active'),
                    paused_node: _('Proxy internet unavailable; direct routing is active'),
                    device_unreachable: _('Device unavailable; device fallback is disabled')
                };
                var text = labels[health.state] || _('Waiting for health checks');
                if (health.checked_at) text += ' · ' + new Date(health.checked_at * 1000).toLocaleTimeString();
                L.dom.content(healthEl, text);
            }

            var dnsEl = container.querySelector('#dns-status');
            if (dnsEl) {
                var dcontent = [];
                if (status.dns_running == 1) {
                    var ip = status.domain_dns_running ? _('Router DNS bridge') : (status.proxy_server_ip_addr || '-');
                    var port = status.domain_dns_running ? '5533' : (status.proxy_server_dns_port || '5353');
                    dcontent.push(E('span', { 'style': 'color: green; font-weight: bold;' }, [ _('running') ]));
                    dcontent.push(' (' + ip + ':');
                    dcontent.push(E('span', { 'style': 'color: #FF9800; font-weight: bold;' }, [ port ]));
                    dcontent.push(')');
                } else {
                    dcontent.push(E('span', { 'style': 'color: red; font-weight: bold;' }, [ _('stopped') ]));
                }
                L.dom.content(dnsEl, dcontent);
            }
        }, this));
    },

    refreshLogs: function() {
        return callGetLogs(500).then(L.bind(function(data) {
            var logEl = document.getElementById('log-content');
            if (logEl) {
                var logs = (data && Array.isArray(data.logs)) ? data.logs : [];
                logEl.value = logs.length > 0 ? logs.join('\n') : _('no logs available');
                if (logs.length > 0) logEl.scrollTop = logEl.scrollHeight;
            }
        }, this));
    },

    handleRestart: function() {
        ui.showModal(null, [
            E('p', { 'class': 'spinning' }, _('Restarting FlowProxy service...'))
        ]);

        return callRestartService().then(L.bind(function(res) {
            ui.hideModal();
            if (res && res.result) {
                ui.addNotification(null, E('p', _('FlowProxy service restarted successfully.')), 'info');
                window.setTimeout(function() {
                    location.reload();
                }, 1500);
            } else {
                ui.addNotification(null, E('p', _('Failed to restart FlowProxy service.')), 'error');
            }
        }, this)).catch(function(err) {
            ui.hideModal();
            ui.addNotification(null, E('p', _('RPC error: %s').format((err && (err.message || String(err))) || 'Unknown error')), 'error');
        });
    },
    handleExportConfig: function() {
        return callExportConfig().then(function(res) {
            if (!res || !res.result) throw new Error(res && res.error || _('Configuration export failed.'));
            var blob = new Blob([JSON.stringify(res.backup, null, 2) + '\n'], { type: 'application/json' });
            var url = URL.createObjectURL(blob);
            var link = E('a', { href: url, download: 'flowproxy-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json' });
            document.body.appendChild(link); link.click(); link.remove();
            window.setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
        }).catch(function(err) { ui.addNotification(null, E('p', err.message), 'danger'); });
    },
    handleImportConfig: function() {
        var input = E('input', { type: 'file', accept: '.json,application/json' });
        var error = E('p', { style: 'color:var(--error-color, #c00)' });
        var button = E('button', { class: 'btn cbi-button cbi-button-apply', type: 'button' }, _('Import and apply'));
        button.addEventListener('click', function() {
            var file = input.files && input.files[0];
            if (!file || file.size > 1048576) {
                L.dom.content(error, _('Choose a FlowProxy JSON backup smaller than 1 MiB.')); return;
            }
            button.disabled = true;
            var reader = new FileReader();
            reader.onload = function() {
                var text = String(reader.result);
                try {
                    var backup = JSON.parse(text);
                    if (backup.format !== 'flowproxy-backup' || backup.version !== 1 || !Array.isArray(backup.sections))
                        throw new Error(_('Unsupported FlowProxy backup format/version.'));
                } catch (err) { L.dom.content(error, err.message); button.disabled = false; return; }
                L.dom.content(error, _('Validating and applying configuration...'));
                uploadImport(text, function(percent) {
                    L.dom.content(error, _('Uploading configuration: %d%%').format(percent));
                }).then(function(res) {
                    if (!res || !res.result) throw new Error(res && res.error || _('Configuration import failed.'));
                    L.dom.content(error, _('Validating and applying configuration...'));
                    return waitForImport(res.ticket, 0);
                }).then(function(res) {
                    if (!res || !res.result) throw new Error((res && res.error || _('Configuration import failed.')) +
                        (res && res.details ? '\n' + res.details : ''));
                    ui.hideModal();
                    ui.addNotification(null, E('p', _('Configuration imported and applied successfully.')), 'info');
                    window.setTimeout(function() { location.reload(); }, 1000);
                }).catch(function(err) { L.dom.content(error, err.message); button.disabled = false; });
            };
            reader.onerror = function() { L.dom.content(error, _('Unable to read the backup file.')); button.disabled = false; };
            reader.readAsText(file);
        });
        ui.showModal(_('Import configuration'), [
            E('p', {}, _('Import replaces all saved FlowProxy settings, rules and lists, including its enable switch. Unsaved page changes will be discarded. Rules are validated first; an apply failure restores the previous configuration.')),
            input, error,
            E('div', { class: 'right' }, [ E('button', { class: 'btn', type: 'button', click: ui.hideModal }, _('Cancel')), ' ', button ])
        ]);
    },
    render: function(data) {
        var self = this;
        var devices = data[1];
        var status = data[2];
        var ifaces = data[3] || [];
        var m, s, o;

        m = new form.Map('flowproxy', _('FlowProxy'),
            _('Traffic diversion based on nftables rules. The service will automatically start/stop when you click "Save & Apply".'));

        if (!document.getElementById('flowproxy-style')) {
            document.head.appendChild(E('style', { id: 'flowproxy-style' }, `
                #log-content { width: 100% !important; height: 60vh; min-height: 400px; font-family: monospace; font-size: 12px; background: #f5f5f5 !important; color: #333 !important; border: 1px solid #ccc !important; padding: 10px; resize: vertical; border-radius: 4px; box-sizing: border-box; }
                .nft-code-view { background: #f5f5f5 !important; color: #333333 !important; padding: 15px !important; font-family: monospace !important; font-size: 12px !important; overflow-x: auto !important; white-space: pre-wrap !important; width: 100% !important; border: 1px solid #cccccc !important; border-radius: 4px; box-sizing: border-box; max-height: 70vh; }
                .nft-comment { color: #777777; font-style: italic; } .nft-keyword { color: #a626a1; font-weight: bold; } .nft-proto { color: #4078f2; } .nft-match { color: #986801; } .nft-action { color: #e45649; font-weight: bold; } .nft-variable { color: #50a14f; font-weight: bold; }
                .cbi-section-table-titles th[data-sortable-row]::after, .cbi-section-table-titles th[data-sortable-row]::before { display: none !important; }
                .cbi-section-table-titles th[data-sortable-row] { pointer-events: none !important; cursor: default !important; }
            `));
        }

        s = m.section(form.NamedSection, 'global', 'flowproxy');
        s.tab('settings', _('Settings'));
        s.tab('policy', _('Pre-routing'));
        s.tab('rules', _('Rules'));
        s.tab('lists', _('Lists'));
        s.tab('advanced', _('Advanced'));
        s.tab('preview', _('Preview'));
        s.tab('logs', _('Logs'));

        // --- Settings ---
        o = s.taboption('settings', form.DummyValue, '_service_status', _('Current Status'));
        o.rawhtml = true;
        o.cfgvalue = function() { return '<div id="service-status" style="display:inline-block;"><em class="spinning">' + _('checking...') + '</em></div>'; };

        o = s.taboption('settings', form.DummyValue, '_dns_status', _('DNS Redirection'));
        o.rawhtml = true;
        o.cfgvalue = function() { return '<div id="dns-status" style="display:inline-block;">-</div>'; };

        s.taboption('settings', form.Flag, 'enabled', _('Enable FlowProxy')).rmempty = false;
        s.taboption('settings', form.Flag, 'dns_proxy_enabled', _('Force upstream DNS to proxy server')).rmempty = false;

        o = s.taboption('settings', form.Value, 'proxy_server_ip_addr', _('Proxy server IP address'));
        o.datatype = 'ip4addr'; o.rmempty = true;
        o.placeholder = '192.168.1.254';

        m.save = function() {
            // DynamicList chips can bypass per-input validation after Enter.
            // Validate the entire list before any UCI changes are staged.
            var values = function(key) {
                var value = s.formvalue('global', key);
                if (value == null) value = uci.get('flowproxy', 'global', key);
                return Array.isArray(value) ? value : (value ? [value] : []);
            };
            var policyError = null;
            if (!values('direct_domain_suffix').every(function(value) {
                var name = String(value).toLowerCase().replace(/^(\*\.|\+\.)/, '').replace(/\.$/, '');
                return name.length <= 253 && /^[a-z0-9_-]+(?:\.[a-z0-9_-]+)*$/.test(name);
            })) policyError = _('Enter a domain name without a URL scheme, path or port.');
            if (!values('direct_domain_keyword').every(function(value) { return String(value).length <= 253 && /^[a-z0-9_.-]+$/i.test(value); }))
                policyError = _('Use letters, digits, dots, underscores or hyphens.');
            if (policyError) {
                ui.addNotification(null, E('p', policyError), 'danger');
                return Promise.reject(new Error(policyError));
            }
            if (!values('node_probe_url').every(function(value) {
                return String(value).length <= 512 && /^https:\/\/[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:\/[A-Za-z0-9_~:/.?&=%+,-]*)?$/.test(value);
            }) || values('node_probe_url').length > 5)
                return Promise.reject(new Error(_('Use up to five HTTPS probe URLs without credentials or whitespace.')));
            var enabled = s.formvalue('global', 'enabled') || uci.get('flowproxy', 'global', 'enabled');
            if (enabled === '1') {
                var ipVal = s.formvalue('global', 'proxy_server_ip_addr') || uci.get('flowproxy', 'global', 'proxy_server_ip_addr');
                var ifaceVal = s.formvalue('global', 'interface') || uci.get('flowproxy', 'global', 'interface');

                if (ipVal && ifaceVal) {
                    var ipInCidr = function(ipStr, cidrStr) {
                        if (!cidrStr || cidrStr.indexOf(':') !== -1 || !ipStr || ipStr.indexOf(':') !== -1) return false;
                        var parts = cidrStr.split('/');
                        var cidrIp = parts[0];
                        var maskBits = parseInt(parts[1] || '32', 10);
                        var ipToNum = function(s) {
                            var p = s.split('.');
                            if (p.length !== 4) return 0;
                            return (((parseInt(p[0], 10) << 24) |
                                     (parseInt(p[1], 10) << 16) |
                                     (parseInt(p[2], 10) << 8) |
                                     parseInt(p[3], 10)) >>> 0);
                        };
                        var ipNum = ipToNum(ipStr);
                        var cidrNum = ipToNum(cidrIp);
                        if (maskBits === 0) return true;
                        var mask = (0xffffffff << (32 - maskBits)) >>> 0;
                        return (ipNum & mask) === (cidrNum & mask);
                    };

                    var target_iface = null;
                    for (var i = 0; i < ifaces.length; i++) {
                        var dev = ifaces[i].getL3Device() || ifaces[i].getDevice();
                        if ((dev && dev.getName() === ifaceVal) || ifaces[i].getName() === ifaceVal) {
                            target_iface = ifaces[i];
                            break;
                        }
                    }

                    if (target_iface) {
                        var ips = target_iface.getIPAddrs();
                        if (ips && ips.length > 0) {
                            var inSubnet = false;
                            for (var j = 0; j < ips.length; j++) {
                                if (ipInCidr(ipVal, ips[j])) {
                                    inSubnet = true;
                                    break;
                                }
                            }
                            if (!inSubnet) {
                                ui.addNotification(null, E('p', _('The proxy server IP address must be within the subnet of the selected interface (%s).').format(ips.join(', '))), 'danger');
                                return Promise.reject(new Error('Proxy IP subnet mismatch'));
                            }
                        }
                    }
                }
            }
            return form.Map.prototype.save.apply(m, arguments);
        };

        o = s.taboption('settings', form.Value, 'proxy_server_dns_port', _('Proxy server DNS port'));
        o.datatype = 'port'; o.default = '5353'; o.rmempty = false;

        o = s.taboption('settings', form.ListValue, 'interface', _('Proxy server interface'));
        devices.forEach(function(d) { o.value(d.getName(), d.getName()); });
        o.default = 'br-lan';

        s.taboption('settings', form.Value, 'traffic_mark', _('Traffic Mark')).datatype = 'or(uinteger, hex)';
        s.taboption('settings', form.Value, 'routing_table', _('Routing Table ID')).datatype = 'and(uinteger,range(1, 4294967295))';
        s.taboption('settings', form.Value, 'rule_priority', _('Rule Priority')).datatype = 'and(uinteger,range(0, 4294967295))';

        o = s.taboption('advanced', form.Flag, 'device_fallback_enabled', _('Fallback when the proxy device is unavailable'));
        o.default = '1'; o.rmempty = false;
        o.description = _('Restore direct routing and the original router DNS when the NAS, SOCKS service or required router DNS bridge is unavailable. Resume diversion automatically after recovery.');
        o = s.taboption('advanced', form.Flag, 'node_fallback_enabled', _('Fallback when proxy internet access is unavailable'));
        o.default = '0'; o.rmempty = false;
        o.description = _('Test HTTPS access through the proxy, using its current domain routing policies. If every probe URL fails repeatedly, restore direct routing. Direct fallback does not make blocked websites accessible.');
        o = s.taboption('advanced', form.Value, 'health_socks_port', _('Proxy SOCKS port'));
        o.default = '7890'; o.datatype = 'port'; o.rmempty = false;
        o.depends('device_fallback_enabled', '1'); o.depends('node_fallback_enabled', '1');
        o = s.taboption('advanced', form.DynamicList, 'node_probe_url', _('Proxy internet probe URLs'));
        o.default = ['https://www.youtube.com/generate_204']; o.depends('node_fallback_enabled', '1');
        o.description = _('Up to five HTTPS URLs. Any successful response keeps diversion active; all URLs must fail to count a failed round. These checks cover the policies used by these domains, not every proxy group.');
        o.validate = function(sid, value) {
            return !value || (value.length <= 512 && /^https:\/\/[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:\/[A-Za-z0-9_~:/.?&=%+,-]*)?$/.test(value)) ||
                _('Use an HTTPS URL without credentials or whitespace.');
        };
        [
            ['health_interval', _('Health check interval (seconds)'), '5', 'range(3,300)'],
            ['health_timeout', _('Probe timeout (seconds)'), '5', 'range(1,30)'],
            ['health_failures', _('Consecutive failures before fallback'), '3', 'range(1,20)'],
            ['health_successes', _('Consecutive successes before recovery'), '2', 'range(1,20)']
        ].forEach(function(item) {
            var field = s.taboption('advanced', form.Value, item[0], item[1]);
            field.default = item[2]; field.datatype = 'and(uinteger,' + item[3] + ')'; field.rmempty = false;
            field.depends('device_fallback_enabled', '1'); field.depends('node_fallback_enabled', '1');
        });
        o = s.taboption('advanced', form.DummyValue, '_health_status', _('Fallback status'));
        o.rawhtml = true; o.cfgvalue = function() { return '<span id="health-status">-</span>'; };
        o = s.taboption('advanced', form.Button, '_export_config', _('Export configuration'));
        o.inputtitle = _('Download backup'); o.inputstyle = 'action';
        o.description = _('Export saved settings, ordered rules, device/IP/port lists, direct domains and referenced list files. Temporary DNS backups and connection caches are excluded.');
        o.onclick = L.bind(this.handleExportConfig, this);
        o = s.taboption('advanced', form.Button, '_import_config', _('Import configuration'));
        o.inputtitle = _('Choose backup and import'); o.inputstyle = 'apply';
        o.onclick = L.bind(this.handleImportConfig, this);

        o = s.taboption('policy', form.Flag, 'apple_ip_direct_enabled', _('Direct Apple service IP ranges'));
        o.rmempty = false;
        o.description = _('Bypass the NAS for the IPv4 ranges in the Apple service list. Rules update daily. Existing manual IP and domain bypass rules remain independent when this switch is off.');
        o = s.taboption('policy', form.Flag, 'microsoft_ip_direct_enabled', _('Direct Microsoft service IP ranges (Microsoft 365)'));
        o.rmempty = false;
        o.description = _('Use the official Microsoft 365 Worldwide and China IPv4 ranges for Office, Outlook, OneDrive and Teams. Rules update daily; this does not bypass all Azure or all Microsoft domains.');
        o = s.taboption('policy', form.DummyValue, '_service_ip_status', _('Service IP rules'));
        o.rawhtml = true;
        o.cfgvalue = function() { return '<div id="service-ip-status">-</div>'; };
        o = s.taboption('policy', form.Button, '_update_service_ips', _('Update service IP rules'));
        o.inputtitle = _('Update now'); o.inputstyle = 'apply';
        o.onclick = function() {
            return callUpdateServiceIPs().then(function(res) {
                ui.addNotification(null, E('p', res.result ? _('Update requested. The status below refreshes automatically; existing rules remain active during download.') : _('Failed to start the update.')), res.result ? 'info' : 'danger');
            });
        };

        // Domain bypass is evaluated before the editable rule tables.
        o = s.taboption('policy', form.Flag, 'domain_direct_enabled', _('Enable direct domains'));
        o.rmempty = false;
        o.description = _('Matching domains are resolved directly by the router. Their IPv4 addresses bypass the NAS. Cached addresses are restored on reload. Devices must use the router DNS; shared CDN addresses can also bypass the proxy.');
        o = s.taboption('policy', form.DynamicList, 'direct_domain_suffix', _('DomainSuffix'));
        o.depends('domain_direct_enabled', '1'); o.placeholder = 'example.com';
        o.description = _('Matches the domain itself and all subdomains, for example example.com and tracker.example.com.');
        o.validate = function(sid, value) {
            if (!value) return true;
            var name = value.toLowerCase().replace(/^(\*\.|\+\.)/, '').replace(/\.$/, '');
            return name.length <= 253 && /^[a-z0-9_-]+(?:\.[a-z0-9_-]+)*$/.test(name) ? true : _('Enter a domain name without a URL scheme, path or port.');
        };
        o = s.taboption('policy', form.DynamicList, 'direct_domain_keyword', _('DomainKeyword'));
        o.depends('domain_direct_enabled', '1'); o.placeholder = 'tracker';
        o.description = _('Case-insensitive substring matching anywhere in the domain name. Broad keywords can bypass unrelated domains.');
        o.validate = function(sid, value) {
            return !value || (value.length <= 253 && /^[a-z0-9_.-]+$/i.test(value)) ? true : _('Use letters, digits, dots, underscores or hyphens.');
        };
        o = s.taboption('policy', form.Value, 'direct_domain_dns', _('Direct domain DNS server'));
        o.depends('domain_direct_enabled', '1'); o.datatype = 'ip4addr'; o.default = '223.5.5.5'; o.rmempty = false;
        o = s.taboption('policy', form.DummyValue, '_direct_domain_status', _('Direct domain status'));
        o.rawhtml = true;
        o.cfgvalue = function() { return '<span id="domain-direct-status">-</span>'; };

        // --- Rules ---
        var nftsets = uci.sections('flowproxy', 'nftset').map(function(ss) { return '@' + ss['.name']; });

        var setupRuleTable = function(type, title, switch_opt) {
            var st = s.taboption('rules', form.SectionValue, '_tab_' + type, form.TableSection, type, title);
            var ss = st.subsection;
            ss.addremove = true; ss.anonymous = true; ss.sortable = true;

            var refreshTable = function() {
                return ss.render().then(function(newNode) {
                    var el = document.getElementById('flowproxy-table-' + type);
                    if (el && el.parentNode) {
                        el.parentNode.replaceChild(newNode, el);
                    }
                });
            };

            var createTemplateButtons = function() {
                var presets = {
                    'priv': { name: 'private (dst)', type: 'dst_ip', val: '@private_dst_ip_v4' },
                    'china': { name: 'china (dst)', type: 'dst_ip', val: '@chnroute_dst_ip_v4' },
                    'src_ip': { name: 'ip (src)', type: 'src_ip', val: '@no_proxy_src_ip_v4' },
                    'dst_ip': { name: 'ip (dst)', type: 'dst_ip', val: '@no_proxy_dst_ip_v4' },
                    'mac': { name: 'mac (src)', type: 'src_mac', val: '@no_proxy_src_mac' },
                    'ports': { name: 'ports (dst)', type: 'dst_port', val: (type === 'tcp_rule') ? '@no_proxy_dst_tcp_ports' : '@no_proxy_dst_udp_ports' }
                };
                var btnGroup = E('div', { 'style': 'display: flex; flex-wrap: wrap; gap: 4px; margin-top: 8px; align-items: center;' }, [ E('small', { 'style': 'margin-right: 5px; color: #888;' }, _('Quick add:')) ]);
                Object.keys(presets).forEach(function(k) {
                    var p = presets[k];
                    
                    var bgColors = {
                        'dst_ip': '#2196F3',
                        'src_ip': '#2196F3',
                        'custom': '#2196F3',
                        'src_mac': '#9C27B0',
                        'dst_port': '#FF9800'
                    };
                    var btnStyle = 'padding: 0 6px; font-size: 0.75rem; height: 22px; line-height: 22px; opacity: 0.9; margin-bottom: 4px; border: none; color: #fff; border-radius: 3px; cursor: pointer;';
                    var bgColor = bgColors[p.type] || '#607d8b';
                    btnStyle += ' background-color: ' + bgColor + ';';

                    btnGroup.appendChild(E('button', {
                        'style': btnStyle,
                        'title': p.val,
                        'click': ui.createHandlerFn(self, function() {
                            var sid = uci.add('flowproxy', type);
                            uci.set('flowproxy', sid, 'enabled', '1');
                            uci.set('flowproxy', sid, 'match_type', p.type);
                            uci.set('flowproxy', sid, 'match_value', p.val);
                            uci.set('flowproxy', sid, 'action', 'return');
                            uci.set('flowproxy', sid, 'counter', '0');
                            return Promise.resolve().then(function() {
                                return m.load().then(function() {
                                    return refreshTable();
                                });
                            });
                        })
                    }, [ E('em', { 'class': 'icon-plus' }), ' ', p.name ]));
                });
                return btnGroup;
            };

            ss.render = function() {
                return form.TableSection.prototype.render.apply(ss).then(function(node) {
                    node.id = 'flowproxy-table-' + type;
                    var titleEl = node.querySelector('h3');
                    if (titleEl) {
                        titleEl.style.display = 'block';
                        var headerRow = E('div', { 'style': 'display: flex; align-items: center; gap: 10px;' }, [
                            E('span', {}, title),
                            E('div', { 'style': 'font-size: 0.8em; font-weight: normal; display: inline-flex; align-items: center; gap: 5px; color: #666;' }, [
                                (function() {
                                    var val = uci.get('flowproxy', 'global', switch_opt);
                                    return E('input', { 'type': 'checkbox', 'style': 'width: 16px; height: 18px; cursor: pointer;', 'checked': (val !== '0') ? 'checked' : null,
                                        'change': function(ev) { uci.set('flowproxy', 'global', switch_opt, ev.target.checked ? '1' : '0'); ui.addNotification(null, E('p', _('Master switch updated.')), 'info'); }
                                    });
                                })(),
                                E('span', {}, _('enable protocol'))
                            ])
                        ]);
                        L.dom.content(titleEl, [ headerRow, createTemplateButtons() ]);
                    }
                    return node;
                });
            };

            ss.renderSectionAdd = function(extra_class) {
                var node = form.TableSection.prototype.renderSectionAdd.apply(this, [extra_class]);
                var label = (type === 'tcp_rule') ? 'TCP' : 'UDP';
                var addBtn = node.querySelector('.cbi-button-add'); if (addBtn) addBtn.innerText = _('Add rule');
                var resetBtn = E('button', { 'class': 'cbi-button cbi-button-reset', 'style': 'margin-left: 10px; border: 1px solid #cc0000; color: #cc0000;',
                    'click': ui.createHandlerFn(self, function() {
                        if (confirm(_('this will delete ALL current %s rules and generate default templates. are you sure?').format(label))) {
                            uci.sections('flowproxy', type).forEach(function(r) { uci.remove('flowproxy', r['.name']); });
                            var defs = [ { t: 'src_mac', v: '@no_proxy_src_mac' }, { t: 'dst_ip', v: '@private_dst_ip_v4' }, { t: 'dst_ip', v: '@chnroute_dst_ip_v4' } ];
                            if (type === 'tcp_rule') defs.push({ t: 'dst_port', v: '@no_proxy_dst_tcp_ports' }); else if (type === 'udp_rule') defs.push({ t: 'dst_port', v: '@no_proxy_dst_udp_ports' });
                            defs.forEach(function(r) { var sid = uci.add('flowproxy', type); uci.set('flowproxy', sid, 'enabled', '1'); uci.set('flowproxy', sid, 'match_type', r.t); uci.set('flowproxy', sid, 'match_value', r.v); uci.set('flowproxy', sid, 'action', 'return'); uci.set('flowproxy', sid, 'counter', '0'); });
                            return Promise.resolve().then(function() {
                                return m.load().then(function() {
                                    return refreshTable();
                                });
                            });
                        }
                    })
                }, [ E('em', { 'class': 'icon-reload' }), ' ', _('reset %s templates').format(label) ]);
                node.appendChild(resetBtn); return node;
            };

            ss.option(form.Flag, 'enabled', _('Enabled')).width = '8%';
            var match_type = ss.option(form.ListValue, 'match_type', _('Match Type'));
            match_type.value('dst_ip', 'dest ip'); match_type.value('src_ip', 'src ip'); match_type.value('src_mac', 'src mac');
            match_type.value('dst_port', 'dest port'); match_type.value('src_port', 'src port'); match_type.value('custom', 'custom (raw)');
            match_type.default = 'dst_ip'; match_type.rmempty = false; match_type.width = '15%';

            var match_value = ss.option(form.Value, 'match_value', _('Match Value')); 
            match_value.rmempty = false; match_value.width = '45%'; 
            nftsets.forEach(function(set) { match_value.value(set); });
            match_value.validate = function(sid, val) {
                if (!val || val === '') return _('Expecting: %s').format(_('Match Value'));
                
                var type = match_type.formvalue(sid);
                if (!type) {
                    var typeEl = document.querySelector('[name="cbid.flowproxy.' + sid + '.match_type"]');
                    if (typeEl && typeEl.value) type = typeEl.value;
                }
                if (!type) type = uci.get('flowproxy', sid, 'match_type');

                if (val.match(/^@/)) {
                    var setName = val.substring(1);
                    // 仅当 section 确实存在时才尝试获取 type，否则不进行类型校验
                    var section = uci.get('flowproxy', setName);
                    var setType = (section && section['.type'] === 'nftset') ? uci.get('flowproxy', setName, 'type') : null;
                    if (!setType) return true; 
                    
                    var expectedType = '';
                    if (type === 'dst_ip' || type === 'src_ip') expectedType = 'ipv4_addr';
                    else if (type === 'src_mac') expectedType = 'ether_addr';
                    else if (type === 'dst_port' || type === 'src_port') expectedType = 'inet_service';
                    
                    if (expectedType && setType !== expectedType && type !== 'custom') {
                        return _('Set type mismatch: expected %s, got %s').format(expectedType, setType);
                    }
                    return true;
                }

                switch (type) {
                    case 'dst_ip':
                    case 'src_ip':
                        if (!val.match(/^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$/)) return _('Invalid IPv4 address or CIDR');
                        break;
                    case 'src_mac':
                        if (!val.match(/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/)) return _('Invalid MAC address');
                        break;
                    case 'dst_port':
                    case 'src_port':
                        if (!val.match(/^[0-9]+(-[0-9]+)?$/)) return _('Invalid port or range');
                        break;
                }
                return true;
            };
            // 联动：当 match_type 改变时，强制触发 match_value 的校验
            match_type.onchange = function(ev, sid, val) {
                var value_input = m.lookupOption('match_value', sid)[0];
                if (value_input) setTimeout(function() { 
                    var el = document.getElementById(value_input.cbid(sid));
                    if (el) {
                        var inputEl = el.tagName === 'INPUT' ? el : el.querySelector('input');
                        if (inputEl) {
                            inputEl.dispatchEvent(new CustomEvent('change', { bubbles: true }));
                            inputEl.dispatchEvent(new CustomEvent('blur', { bubbles: true }));
                            inputEl.dispatchEvent(new CustomEvent('input', { bubbles: true }));
                        }
                    }
                }, 0);
            };
            ss.option(form.Flag, 'counter', _('Counter')).width = '8%';
            o = ss.option(form.ListValue, 'action', _('Action')); o.value('return', 'return'); o.value('accept', 'accept'); o.value('drop', 'drop'); o.default = 'return'; o.width = '12%';
        };
        setupRuleTable('tcp_rule', _('TCP Matching Rules'), 'tcp_enabled');
        setupRuleTable('udp_rule', _('UDP Matching Rules'), 'udp_enabled');

        // --- Lists ---
        var predefined = [ { id: 'no_proxy_src_mac', name: _('no_proxy_src_mac'), type: 'macaddr' }, { id: 'no_proxy_src_ip_v4', name: _('no_proxy_src_ip_v4'), type: 'or(ip4addr, cidr4)' }, { id: 'no_proxy_dst_ip_v4', name: _('no_proxy_dst_ip_v4'), type: 'or(ip4addr, cidr4)' }, { id: 'no_proxy_dst_tcp_ports', name: _('no_proxy_dst_tcp_ports'), type: 'or(port, portrange)' }, { id: 'no_proxy_dst_udp_ports', name: _('no_proxy_dst_udp_ports'), type: 'or(port, portrange)' } ];
        predefined.forEach(function(p) {
            var sl = s.taboption('lists', form.SectionValue, '_list_' + p.id, form.NamedSection, p.id, 'nftset', p.name + ' (@' + p.id + ')');
            sl.subsection.option(form.Flag, 'enabled', _('Enabled')).default = '1';
            sl.subsection.option(form.DynamicList, 'elements', _('Elements')).datatype = p.type;
        });
        var spriv = s.taboption('lists', form.SectionValue, '_list_priv', form.NamedSection, 'private_dst_ip_v4', 'nftset', _('private_dst_ip_v4') + ' (@private_dst_ip_v4)');
        spriv.subsection.option(form.Flag, 'enabled', _('Enabled')).default = '1';
        spriv.subsection.option(form.Flag, 'auto_generate', _('auto_generate')).default = '1';
        o = spriv.subsection.option(form.DynamicList, 'elements', _('elements')); o.datatype = 'cidr4'; o.depends('auto_generate', '0');

        var sc = s.taboption('lists', form.SectionValue, '_list_chnroute', form.NamedSection, 'chnroute_dst_ip_v4', 'nftset', _('chnroute_dst_ip_v4') + ' (@chnroute_dst_ip_v4)');
        sc.subsection.option(form.Flag, 'enabled', _('Enabled')).default = '1';
        o = sc.subsection.option(form.Value, 'file_path', _('File Path')); o.default = '/usr/share/flowproxy/chnroute.txt';
        o.render = function(sid) {
            return form.Value.prototype.render.apply(this, arguments).then(function(node) {
                var path = uci.get('flowproxy', sid, 'file_path') || '/usr/share/flowproxy/chnroute.txt';
                var resNode = E('span', { 'style': 'margin-left: 10px; font-weight: bold; color: #444;', 'id': 'line-count-status' }, [ '...' ]);
                var input = node.querySelector('input'); if (input) input.parentNode.appendChild(resNode);
                fs.exec('/usr/bin/wc', ['-l', path]).then(function(res) { L.dom.content(resNode, (res.code === 0) ? [ _('(%d lines)').format(res.stdout.trim().split(' ')[0]) ] : [ _('(n/a)') ]); });
                return node;
            });
        };
        sc.subsection.option(form.Value, 'download_url', _('Download URL'));
        o = sc.subsection.option(form.Button, '_download', _('Update Chnroute')); o.inputstyle = 'apply';
        o.onclick = function(ev, sid) {
            var urlOpt = m.lookupOption('download_url', sid)[0];
            var url = urlOpt ? urlOpt.formvalue(sid) : uci.get('flowproxy', sid, 'download_url');
            var pathOpt = m.lookupOption('file_path', sid)[0];
            var path = pathOpt ? pathOpt.formvalue(sid) : uci.get('flowproxy', sid, 'file_path');
            if (!path) path = '/usr/share/flowproxy/chnroute.txt';
            if (!url) { ui.addNotification(null, E('p', _('Please set download_url first')), 'error'); return; }
            ui.showModal(null, [ E('p', { 'class': 'spinning', 'id': 'download-msg' }, [ _('Downloading chnroute data...') ]) ]);
            return fs.exec('/usr/bin/wget', ['-q', '-O', path, url, '--timeout=10', '--no-check-certificate']).then(function(res) {
                var msgEl = document.getElementById('download-msg');
                if (res.code === 0) {
                    if (msgEl) { msgEl.classList.remove('spinning'); L.dom.content(msgEl, [ _('Updated successfully.') ]); }
                    var cn = document.getElementById('line-count-status'); if (cn) fs.exec('/usr/bin/wc', ['-l', path]).then(function(r) { L.dom.content(cn, (r.code === 0) ? [ _('(%d lines)').format(r.stdout.trim().split(' ')[0]) ] : [ _('(n/a)') ]); });
                    setTimeout(ui.hideModal, 1500);
                } else { ui.hideModal(); ui.addNotification(null, E('p', _('Download failed')), 'error'); }
            }).catch(function(e) { ui.hideModal(); ui.addNotification(null, E('p', _('Error: %s').format(e.message)), 'error'); });
        };

        var sg = s.taboption('lists', form.SectionValue, '_list_custom', form.GridSection, 'nftset', _('Custom nftables sets'));
        sg.subsection.addremove = true; sg.subsection.anonymous = false; sg.subsection.nodescription = true;
        sg.subsection.filter = function(sid) { var pre = predefined.map(function(p){return p.id}); pre.push('private_dst_ip_v4','chnroute_dst_ip_v4'); return pre.indexOf(sid) === -1; };
        sg.subsection.option(form.Flag, 'enabled', _('Enabled')).default = '1';
        o = sg.subsection.option(form.ListValue, 'type', _('Element Type')); o.value('ipv4_addr', 'IPv4 Address/CIDR'); o.value('ether_addr', 'MAC Address'); o.value('inet_service', 'Port/Service'); o.default = 'ipv4_addr';
        sg.subsection.option(form.DynamicList, 'elements', _('Elements'));

        // --- Preview & Logs ---
        var sp = s.taboption('preview', form.SectionValue, '_preview_section', form.NamedSection, 'global', 'flowproxy');
        sp.subsection.tab('generated', _('Generated Config')); sp.subsection.tab('runtime', _('Live Runtime State'));
        
        o = sp.subsection.taboption('generated', form.DummyValue, '_preview_gen');
        o.render = function() {
            var node = E('div', { 'style': 'width:100%; box-sizing:border-box; margin-top: 10px;' }, [
                E('div', { 'style': 'margin-bottom: 10px' }, [ 
                    E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function() {
                        var el = document.getElementById('gen-code');
                        if (el) { navigator.clipboard.writeText(el.innerText); ui.addNotification(null, E('p', _('Copied')), 'info'); }
                    } }, [ _('Copy Config') ]) 
                ]),
                E('pre', { 'class': 'nft-code-view', 'id': 'gen-code' }, [ _('loading...') ])
            ]);
            callGenerateNftConfig().then(function(res) {
                var el = node.querySelector('#gen-code');
                if (el) el.innerHTML = self.highlightNft(res.config || '');
            });
            return node;
        };

        o = sp.subsection.taboption('runtime', form.DummyValue, '_preview_run');
        o.render = function() {
            var node = E('div', { 'style': 'width:100%; box-sizing:border-box; margin-top: 10px;' }, [
                E('div', { 'style': 'margin-bottom: 10px' }, [ 
                    E('button', { 'class': 'cbi-button cbi-button-refresh', 'click': function() { location.reload(); } }, [ _('Refresh Status') ]) 
                ]),
                E('pre', { 'class': 'nft-code-view', 'id': 'run-code' }, [ _('loading...') ])
            ]);
            callGetRuntimeConfig().then(function(res) {
                var el = node.querySelector('#run-code');
                if (el) el.innerHTML = self.highlightNft(res.runtime || '');
            });
            return node;
        };

        o = s.taboption('logs', form.ListValue, 'log_level', _('Log Level'));
        o.value('debug'); o.value('info'); o.value('warn'); o.value('error'); o.default = 'info';
        s.taboption('logs', form.Value, 'log_size', _('Log Size (KB)')).datatype = 'uinteger';
        o = s.taboption('logs', form.DummyValue, '_log_view');
        o.render = function() {
            var node = E('div', { 'style': 'width:100%; box-sizing:border-box; margin-top: 15px;' }, [
                E('div', { 'style': 'margin-bottom: 5px; text-align: left;' }, [
                    E('button', { 'class': 'cbi-button cbi-button-refresh', 'click': L.bind(self.refreshLogs, self) }, [ _('Refresh Logs') ]),
                    E('button', { 'class': 'cbi-button cbi-button-reset', 'style': 'margin-left: 10px;', 'click': L.bind(function() { if(confirm(_('Clear logs?'))) callClearLogs().then(L.bind(self.refreshLogs, self)); }, self) }, [ _('Clear Logs') ])
                ]),
                E('textarea', { 'id': 'log-content', 'readonly': true }, [ _('loading logs...') ])
            ]);
            callGetLogs(500).then(function(data) {
                var logEl = node.querySelector('#log-content');
                if (logEl) {
                    var logs = (data && Array.isArray(data.logs)) ? data.logs : [];
                    logEl.value = logs.length > 0 ? logs.join('\n') : _('no logs available');
                    if (logs.length > 0) logEl.scrollTop = logEl.scrollHeight;
                }
            });
            return node;
        };

        return m.render().then(L.bind(function(node) {
            this.refreshStatus(m, node);
            poll.add(L.bind(function() { if (!document.body.contains(node)) return false; return this.refreshStatus(m, node); }, this), 5);
            return node;
        }, this));
    }
});
