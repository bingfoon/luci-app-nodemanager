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
		return nm.call('load').then(function(resp) {
			return (resp && resp.ok) ? resp.data : {};
		});
	},

	render: function(data) {
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
			E('div', {'style': 'display:flex;gap:8px;margin-bottom:16px;'}, [
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'id': 'nm-save-btn',
					'click': function(ev) { self.handleSaveDns(ev.target); }
				}, '💾 ' + _('Save'))
			])
		].concat(sections));
	},

	renderSection: function(sec) {
		var self = this;
		var items = self.dns[sec.key] || [];
		var bodyId = 'nm-dns-' + sec.key.replace(/-/g, '_');

		var tbody = E('tbody', {'id': bodyId});
		for (var i = 0; i < items.length; i++) {
			tbody.appendChild(self.createRow(items[i], sec.placeholder));
		}

		return E('div', {'class': 'cbi-section', 'style': 'margin-bottom:16px;'}, [
			E('div', {'style': 'display:flex;align-items:center;justify-content:space-between;margin-bottom:8px;'}, [
				E('h3', {'style': 'margin:0;font-size:14px;'}, _(sec.label)),
				E('button', {
					'class': 'cbi-button cbi-button-add',
					'style': 'padding:2px 10px;font-size:12px;',
					'data-section': bodyId,
					'data-placeholder': sec.placeholder,
					'click': function(ev) {
						var bid = ev.target.getAttribute('data-section');
						var ph = ev.target.getAttribute('data-placeholder');
						var tb = document.getElementById(bid);
						var tr = self.createRow('', ph);
						tb.appendChild(tr);
						tr.querySelector('[data-field="dns"]').focus();
					}
				}, '+ ' + _('Add'))
			]),
			E('table', {'class': 'table cbi-section-table', 'style': 'table-layout:auto;width:100%;'}, [
				E('thead', {}, [
					E('tr', {'class': 'tr table-titles'}, [
						E('th', {'class': 'th'}, _('Address')),
						E('th', {'class': 'th', 'style': 'width:60px'}, _('Action'))
					])
				]),
				tbody
			])
		]);
	},

	createRow: function(val, placeholder) {
		val = val || '';
		placeholder = placeholder || '';
		return E('tr', {'class': 'tr'}, [
			E('td', {'class': 'td'}, [
				E('input', {
					'class': 'cbi-input-text',
					'data-field': 'dns',
					'value': val,
					'placeholder': placeholder,
					'style': 'width:100%;min-width:200px;box-sizing:border-box;'
				})
			]),
			E('td', {'class': 'td', 'style': 'width:60px;'}, [
				E('button', {
					'class': 'cbi-button cbi-button-remove',
					'style': 'padding:2px 6px;',
					'click': function(ev) {
						ev.target.closest('tr').remove();
					}
				}, '✕')
			])
		]);
	},

	handleSaveDns: function(btn) {
		var dns_map = {};
		for (var i = 0; i < DNS_SECTIONS.length; i++) {
			var sec = DNS_SECTIONS[i];
			var safeId = sec.key.replace(/-/g, '_');
			var rows = document.querySelectorAll('#nm-dns-' + safeId + ' tr');
			var list = [];
			for (var j = 0; j < rows.length; j++) {
				var v = rows[j].querySelector('[data-field="dns"]').value.trim();
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
	handleReset: null
});
