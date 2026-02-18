'use strict';
'require view';
'require ui';
'require form';
'require nodemanager.common as nm';

return view.extend({
	settings: {},
	status: null,

	load: function() {
		return nm.call('load').then(function(resp) {
			return (resp && resp.ok) ? resp.data : {};
		});
	},

	render: function(data) {
		var self = this;
		self.settings = data.settings || {};
		self.status = data.status || {};

		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('Settings')),
			nm.renderStatusBar(self.status),
			self.renderForm()
		]);
	},

	renderForm: function() {
		var self = this;
		var s = self.settings;

		var pathInput = E('input', {
			'class': 'cbi-input-text',
			'id': 'nm-path',
			'value': s.path || '/etc/nikki/profiles/config.yaml',
			'style': 'width:100%;'
		});

		var tplInput = E('input', {
			'class': 'cbi-input-text',
			'id': 'nm-template',
			'value': s.template || '/usr/share/nodemanager/config.template.yaml',
			'style': 'width:100%;'
		});

		var createCheck = E('input', {
			'type': 'checkbox',
			'id': 'nm-create'
		});

		return E('div', {'class': 'cbi-section'}, [
			E('div', {'class': 'cbi-value'}, [
				E('label', {'class': 'cbi-value-title'}, _('Config file path')),
				E('div', {'class': 'cbi-value-field'}, [pathInput])
			]),
			E('div', {'class': 'cbi-value'}, [
				E('label', {'class': 'cbi-value-title'}, _('Template file path')),
				E('div', {'class': 'cbi-value-field'}, [
					tplInput,
					E('div', {'class': 'cbi-value-description'},
						_('Used when creating config file. Leave default unless customized.'))
				])
			]),
			E('div', {'class': 'cbi-value'}, [
				E('label', {'class': 'cbi-value-title'}, _('Create if missing')),
				E('div', {'class': 'cbi-value-field'}, [
					createCheck,
					E('span', {'style': 'margin-left:8px;'},
						_('Create config file from template if it does not exist'))
				])
			]),
			E('div', {'style': 'display:flex;gap:8px;margin-top:16px;'}, [
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'click': function(ev) { self.handleSaveSettings(ev.target); }
				}, '💾 ' + _('Save')),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': function(ev) {
						ev.target.disabled = true;
						ev.target.textContent = _('Processing...');
						nm.call('service', {cmd: 'restart'})
							.then(function(resp) {
								if (resp && resp.ok) {
									ui.addNotification(null, E('p', _('Service restarted')), 'info');
									window.setTimeout(function() { location.reload(); }, 1000);
								} else {
									ui.addNotification(null, E('p', (resp && resp.err) || _('Failed')), 'error');
								}
							})
							.catch(function(e) {
								ui.addNotification(null, E('p', e.message), 'error');
							})
							.finally(function() {
								ev.target.disabled = false;
								ev.target.textContent = '🔄 ' + _('Restart nikki');
							});
					}
				}, '🔄 ' + _('Restart nikki'))
			])
		]);
	},

	handleSaveSettings: function(btn) {
		var path = document.getElementById('nm-path').value;
		var template = document.getElementById('nm-template').value;
		var create = document.getElementById('nm-create').checked;

		btn.disabled = true;
		btn.textContent = _('Saving...');
		nm.call('save_settings', {path: path, template: template, create_if_missing: create})
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
