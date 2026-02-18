'use strict';
'require view';
'require ui';
'require nodemanager.common as nm';

return view.extend({
	status: null,

	load: function() {
		return nm.call('load').then(function(resp) {
			return (resp && resp.ok) ? resp.data : {};
		});
	},

	render: function(data) {
		var self = this;
		self.status = data.status || {};

		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('Logs')),
			nm.renderStatusBar(self.status),
			self.renderToolbar(),
			self.renderLogArea()
		]);
	},

	renderToolbar: function() {
		var self = this;
		return E('div', {'style': 'display:flex;gap:8px;margin-bottom:16px;'}, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': function() { self.refreshLogs(); }
			}, '🔄 ' + _('Refresh'))
		]);
	},

	renderLogArea: function() {
		return E('div', {'class': 'cbi-section'}, [
			E('pre', {
				'id': 'nm-log-content',
				'style': 'background:#1e1e2e;color:#cdd6f4;padding:16px;border-radius:8px;' +
					'font-family:monospace;font-size:12px;line-height:1.6;' +
					'max-height:500px;overflow:auto;white-space:pre-wrap;word-break:break-all;'
			}, _('Loading...'))
		]);
	},

	refreshLogs: function() {
		var pre = document.getElementById('nm-log-content');
		if (pre) pre.textContent = _('Loading...');

		nm.call('get_logs')
			.then(function(resp) {
				if (resp && resp.ok && resp.data) {
					pre.textContent = resp.data.log || _('No logs found');
				} else {
					pre.textContent = (resp && resp.err) || _('Failed to load logs');
				}
			})
			.catch(function(e) {
				pre.textContent = _('Error: ') + e.message;
			});
	},

	handleSaveApply: null,
	handleReset: null
});
