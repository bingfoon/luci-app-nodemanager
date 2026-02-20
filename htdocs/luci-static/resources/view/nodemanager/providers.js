'use strict';
'require view';
'require ui';
'require nodemanager.common as nm';

return view.extend({
	providers: [],
	status: null,

	load: function() {
		return nm.call('load').then(function(resp) {
			return (resp && resp.ok) ? resp.data : {};
		});
	},

	render: function(data) {
		var self = this;
		self.providers = data.providers || [];
		self.status = data.status || {};

		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('Proxy Providers')),
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
				'click': function(ev) { self.handleSaveProviders(ev.target); }
			}, '💾 ' + _('Save'))
		]);
	},

	renderTable: function() {
		var self = this;
		var thead = E('tr', {'class': 'tr table-titles'}, [
			E('th', {'class': 'th'}, _('Provider Name')),
			E('th', {'class': 'th'}, _('Subscription URL')),
			E('th', {'class': 'th', 'style': 'width:60px'}, _('Action'))
		]);

		var tbody = E('tbody', {'id': 'nm-provider-body'});
		for (var i = 0; i < self.providers.length; i++) {
			tbody.appendChild(self.createRow(self.providers[i]));
		}

		return E('table', {'class': 'table cbi-section-table'}, [
			E('thead', {}, [thead]),
			tbody
		]);
	},

	createRow: function(p) {
		p = p || {name: '', url: ''};
		return E('tr', {'class': 'tr'}, [
			E('td', {'class': 'td'}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'name', 'value': p.name, 'required': '',
					'placeholder': _('e.g. MyAirport')})
			]),
			E('td', {'class': 'td'}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'url', 'value': p.url, 'required': '',
					'placeholder': 'https://...'})
			]),
			E('td', {'class': 'td'}, [
				E('button', {
					'class': 'cbi-button cbi-button-remove',
					'style': 'width:24px;height:24px;padding:0;font-size:12px;line-height:24px;text-align:center;',
					'click': function(ev) {
						if (confirm(_('Delete this row?'))) {
							ev.target.closest('tr').remove();
						}
					}
				}, '🗑️')
			])
		]);
	},

	addRow: function() {
		var tbody = document.getElementById('nm-provider-body');
		var tr = this.createRow(null);
		tbody.appendChild(tr);
		tr.querySelector('[data-field="name"]').focus();
	},

	handleSaveProviders: function(btn) {
		var rows = document.querySelectorAll('#nm-provider-body tr');
		var list = [];
		for (var i = 0; i < rows.length; i++) {
			var tr = rows[i];
			list.push({
				name: tr.querySelector('[data-field="name"]').value,
				url:  tr.querySelector('[data-field="url"]').value
			});
		}
		btn.disabled = true;
		btn.textContent = _('Saving...');
		nm.call('save_providers', {providers: list})
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
