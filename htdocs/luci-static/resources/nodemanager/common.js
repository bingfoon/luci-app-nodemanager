'use strict';
'require baseclass';
'require request';
'require ui';

return baseclass.extend({
	apiUrl: L.url('admin/services/nodemanager/api'),

	call: function(action, data) {
		var url = this.apiUrl + '?action=' + encodeURIComponent(action);
		if (data) {
			return request.post(url, JSON.stringify(data), {
				'Content-Type': 'application/json'
			}).then(function(resp) { return resp.json(); });
		}
		return request.get(url).then(function(resp) { return resp.json(); });
	},

	renderStatusBar: function(status) {
		var running = status && status.running;
		var version = (status && status.version) || '';
		var self = this;

		var dot = E('span', {
			'style': 'display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;' +
				'background:' + (running ? '#51cf66' : '#ff6b6b')
		});

		var label = E('span', {}, running
			? _('nikki running') + (version ? ' (v' + version + ')' : '')
			: _('nikki stopped'));

		var btn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:12px;padding:2px 12px;font-size:12px;',
			'click': function(ev) {
				ev.target.disabled = true;
				ev.target.textContent = _('Processing...');
				self.call('service', { cmd: running ? 'restart' : 'start' })
					.then(function() { location.reload(); })
					.catch(function(e) { ui.addNotification(null, E('p', e.message)); })
					.finally(function() { ev.target.disabled = false; });
			}
		}, running ? _('Restart') : _('Start'));

		return E('div', {
			'class': 'cbi-section',
			'style': 'display:flex;align-items:center;padding:8px 16px;margin-bottom:16px;' +
				'border:1px solid ' + (running ? '#b2f2bb' : '#ffc9c9') + ';' +
				'border-radius:6px;background:' + (running ? '#ebfbee' : '#fff5f5')
		}, [dot, label, btn]);
	},

	delayBadge: function(delay) {
		if (delay === null || delay === undefined || delay < 0) {
			return E('span', { 'style': 'color:#868e96' }, '–');
		}
		var color = delay < 200 ? '#51cf66' : delay < 500 ? '#fcc419' : '#ff6b6b';
		return E('span', { 'style': 'font-weight:bold;color:' + color }, delay + 'ms');
	},

	testProxy: function(name) {
		return request.get(
			this.apiUrl + '?action=test_proxy&name=' + encodeURIComponent(name)
		).then(function(r) { return r.json(); });
	}
});
