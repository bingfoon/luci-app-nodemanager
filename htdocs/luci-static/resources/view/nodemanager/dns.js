'use strict';
'require view';
'require ui';
'require nodemanager.common as nm';

return view.extend({
	dns: [],
	status: null,

	load: function() {
		return nm.call('load').then(function(resp) {
			return (resp && resp.ok) ? resp.data : {};
		});
	},

	render: function(data) {
		var self = this;
		self.dns = data.dns || [];
		self.status = data.status || {};

		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('DNS Servers')),
			nm.renderStatusBar(self.status),
			self.renderToolbar(),
			self.renderTable()
		]);
	},

	renderToolbar: function() {
		var self = this;
		return E('div', {'style': 'display:flex;gap:8px;margin-bottom:16px;'}, [
			E('button', {
				'class': 'cbi-button cbi-button-add',
				'click': function() { self.addRow(); }
			}, '➕ ' + _('Add')),
			E('button', {
				'class': 'cbi-button cbi-button-save',
				'id': 'nm-save-btn',
				'click': function(ev) { self.handleSaveDns(ev.target); }
			}, '💾 ' + _('Save'))
		]);
	},

	renderTable: function() {
		var self = this;
		var thead = E('tr', {'class': 'tr table-titles'}, [
			E('th', {'class': 'th'}, _('DNS Server IP')),
			E('th', {'class': 'th', 'style': 'width:60px'}, _('Action'))
		]);

		var tbody = E('tbody', {'id': 'nm-dns-body'});
		for (var i = 0; i < self.dns.length; i++) {
			tbody.appendChild(self.createRow(self.dns[i]));
		}

		return E('table', {'class': 'table cbi-section-table'}, [
			E('thead', {}, [thead]),
			tbody
		]);
	},

	createRow: function(ip) {
		ip = ip || '';
		return E('tr', {'class': 'tr'}, [
			E('td', {'class': 'td'}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'ip', 'value': ip, 'required': '',
					'placeholder': _('e.g. 223.5.5.5')})
			]),
			E('td', {'class': 'td'}, [
				E('button', {
					'class': 'cbi-button cbi-button-remove',
					'style': 'padding:2px 6px;',
					'click': function(ev) {
						if (confirm(_('Delete this row?'))) {
							ev.target.closest('tr').remove();
						}
					}
				}, '✕')
			])
		]);
	},

	addRow: function() {
		var tbody = document.getElementById('nm-dns-body');
		var tr = this.createRow('');
		tbody.appendChild(tr);
		tr.querySelector('[data-field="ip"]').focus();
	},

	handleSaveDns: function(btn) {
		var rows = document.querySelectorAll('#nm-dns-body tr');
		var list = [];
		for (var i = 0; i < rows.length; i++) {
			list.push(rows[i].querySelector('[data-field="ip"]').value);
		}
		btn.disabled = true;
		btn.textContent = _('Saving...');
		nm.call('save_dns', {dns: list})
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
