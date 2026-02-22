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
			? _('nikki running') + (version ? ' (' + version + ')' : '')
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

	formatBytes: function(bytes) {
		if (bytes === null || bytes === undefined || bytes < 0) return '–';
		if (bytes === 0) return '0 B';
		var units = ['B', 'KB', 'MB', 'GB', 'TB'];
		var i = Math.floor(Math.log(bytes) / Math.log(1024));
		if (i >= units.length) i = units.length - 1;
		return (bytes / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 1) + ' ' + units[i];
	},

	testProxy: function(name) {
		return request.get(
			this.apiUrl + '?action=test_proxy&name=' + encodeURIComponent(name)
		).then(function(r) { return r.json(); });
	},

	checkDevice: function() {
		return this.call('check_device').then(function(resp) {
			return (resp && resp.ok) ? resp.data : { allowed: true };
		});
	},

	renderDeviceBlock: function(info) {
		var msg = info.message || _('This plugin is not supported on the current device');
		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('Node Manager')),
			E('div', {
				'class': 'cbi-section',
				'style': 'text-align:center;padding:40px 20px;border:1px solid #ffc9c9;border-radius:8px;background:#fff5f5;'
			}, [
				E('p', {'style': 'font-size:48px;margin:0;'}, '🚫'),
				E('p', {'style': 'font-size:16px;font-weight:bold;color:#c92a2a;margin:16px 0 8px;'}, msg),
				E('p', {'style': 'color:#868e96;font-size:13px;'}, _('Current device') + ': ' + (info.board || _('Unknown'))),
				E('div', {'style': 'margin-top:24px;'}, [
					E('img', {
						'src': L.resource('nodemanager/qrcode.png'),
						'style': 'max-width:200px;border-radius:12px;box-shadow:0 4px 16px rgba(0,0,0,0.15);'
					}),
					E('p', {'style': 'font-size:18px;font-weight:600;color:#2d3436;margin:16px 0 8px;'}, '加入AI搞钱英雄会'),
					E('p', {'style': 'font-size:14px;color:#636e72;margin:0;'}, '参与更多AI变现项目')
				])
			])
		]);
	}
});
