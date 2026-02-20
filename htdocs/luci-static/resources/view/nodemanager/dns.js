'use strict';
'require view';
'require ui';
'require nodemanager.common as nm';

var DNS_SECTIONS = [
	{key: 'default-nameserver',        label: 'Default Nameserver',        placeholder: 'e.g. 223.5.5.5'},
	{key: 'proxy-server-nameserver',   label: 'Proxy Server Nameserver',   placeholder: 'e.g. https://dns.alidns.com/dns-query'},
	{key: 'direct-nameserver',         label: 'Direct Nameserver',         placeholder: 'e.g. https://dns.alidns.com/dns-query'},
	{key: 'nameserver',               label: 'Nameserver',                placeholder: 'e.g. https://8.8.8.8/dns-query'}
];

return view.extend({
	dns: {},
	status: null,

	load: function() {
		return nm.checkDevice().then(function(dev) {
			if (!dev.allowed) return { _deviceBlocked: true, _deviceInfo: dev };
			return nm.call('load').then(function(resp) {
				return (resp && resp.ok) ? resp.data : {};
			});
		});
	},

	render: function(data) {
		if (data._deviceBlocked) return nm.renderDeviceBlock(data._deviceInfo);
		var self = this;
		self.dns = data.dns || {};
		self.status = data.status || {};

		var sections = [];
		for (var i = 0; i < DNS_SECTIONS.length; i++) {
			sections.push(self.renderSection(DNS_SECTIONS[i]));
		}

		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('DNS Servers')),
			nm.renderStatusBar(self.status),
			E('div', {'style': 'margin-bottom:12px;'}, [
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'id': 'nm-save-btn',
					'click': function(ev) { self.handleSaveDns(ev.target); }
				}, '💾 ' + _('Save'))
			]),
			E('div', {'id': 'nm-dns-sections'}, sections)
		]);
	},

	renderSection: function(sec) {
		var self = this;
		var items = self.dns[sec.key] || [];
		var safeId = 'nm-dns-' + sec.key.replace(/-/g, '_');

		var listDiv = E('div', {'id': safeId});
		for (var i = 0; i < items.length; i++) {
			listDiv.appendChild(self.createRow(items[i], sec.placeholder));
		}

		return E('div', {'style': 'margin-bottom:12px;padding:8px 12px;background:#f9f9f9;border:1px solid #e5e5e5;border-radius:4px;'}, [
			E('div', {'style': 'display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;'}, [
				E('strong', {'style': 'font-size:13px;'}, _(sec.label)),
				E('button', {
					'class': 'cbi-button cbi-button-add',
					'style': 'padding:1px 8px;font-size:11px;',
					'data-section': safeId,
					'data-placeholder': sec.placeholder,
					'click': function(ev) {
						var sid = ev.target.getAttribute('data-section');
						var ph = ev.target.getAttribute('data-placeholder');
						var container = document.getElementById(sid);
						var row = self.createRow('', ph);
						container.appendChild(row);
						row.querySelector('input').focus();
					}
				}, '+ ' + _('Add'))
			]),
			listDiv
		]);
	},

	createRow: function(val, placeholder) {
		val = val || '';
		placeholder = placeholder || '';
		var resultSpan = E('span', {'style': 'font-size:11px;min-width:40px;text-align:center;'}, '');
		var row = E('div', {'style': 'display:flex;align-items:center;gap:6px;margin-bottom:4px;'}, [
			E('input', {
				'class': 'cbi-input-text',
				'data-field': 'dns',
				'value': val,
				'placeholder': placeholder,
				'style': 'width:50%;box-sizing:border-box;padding:3px 6px;font-size:13px;'
			}),
			resultSpan,
			E('button', {
				'class': 'cbi-button',
				'style': 'width:24px;height:24px;padding:0;font-size:12px;line-height:24px;text-align:center;flex-shrink:0;',
				'title': _('Test DNS'),
				'click': function(ev) {
					var btn = ev.target;
					var input = btn.closest('div').querySelector('[data-field="dns"]');
					var badge = btn.closest('div').querySelector('span');
					var server = input.value.trim();
					if (!server) return;
					btn.disabled = true;
					badge.textContent = '⏳';
					badge.style.color = '#868e96';
					nm.call('test_dns', {server: server})
						.then(function(resp) {
							if (resp && resp.ok && resp.data) {
								var ms = resp.data.delay;
								badge.textContent = ms != null ? ms + 'ms' : '✓';
								badge.style.color = ms < 200 ? '#2ecc71' : ms < 500 ? '#f39c12' : '#e74c3c';
							} else {
								badge.textContent = '✗';
								badge.style.color = '#e74c3c';
							}
						})
						.catch(function() {
							badge.textContent = '✗';
							badge.style.color = '#e74c3c';
						})
						.finally(function() { btn.disabled = false; });
				}
			}, '⚡'),
			E('button', {
				'class': 'cbi-button cbi-button-remove',
				'style': 'width:24px;height:24px;padding:0;font-size:12px;line-height:24px;text-align:center;flex-shrink:0;',
				'click': function(ev) {
					ev.target.closest('div[style]').remove();
				}
			}, '🗑️')
		]);
		return row;
	},

	handleSaveDns: function(btn) {
		var dns_map = {};
		for (var i = 0; i < DNS_SECTIONS.length; i++) {
			var sec = DNS_SECTIONS[i];
			var safeId = sec.key.replace(/-/g, '_');
			var inputs = document.querySelectorAll('#nm-dns-' + safeId + ' [data-field="dns"]');
			var list = [];
			for (var j = 0; j < inputs.length; j++) {
				var v = inputs[j].value.trim();
				if (v) list.push(v);
			}
			dns_map[sec.key] = list;
		}

		btn.disabled = true;
		btn.textContent = _('Saving...');
		nm.call('save_dns', {dns: dns_map})
			.then(function(resp) {
				if (resp && resp.ok) {
					ui.addNotification(null, E('p', _('Saved successfully')), 'info');
					window.setTimeout(function() { location.reload(); }, 800);
				} else {
					ui.addNotification(null, E('p', (resp && resp.err) || _('Save failed')), 'error');
				}
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', _('Network error: ') + e.message), 'error');
			})
			.finally(function() {
				btn.disabled = false;
				btn.textContent = '💾 ' + _('Save');
			});
	},

	handleSaveApply: null,
	handleReset: null,
	addFooter: function() { return E('div'); }
});
