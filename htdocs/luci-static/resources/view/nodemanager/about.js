'use strict';
'require view';
'require ui';

return view.extend({
	render: function() {
		return E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('About')),
			E('div', {'style': 'text-align:center;padding:40px 20px;'}, [
				E('div', {'style': 'margin-bottom:24px;'}, [
					E('img', {
						'src': L.resource('nodemanager/qrcode.png'),
						'style': 'max-width:280px;border-radius:12px;box-shadow:0 4px 16px rgba(0,0,0,0.15);'
					})
				]),
				E('p', {'style': 'font-size:18px;font-weight:600;color:#2d3436;margin:0 0 8px;'}, '加入AI搞钱英雄会'),
				E('p', {'style': 'font-size:14px;color:#636e72;margin:0;'}, '参与更多AI变现项目')
			])
		]);
	},

	handleSaveApply: null,
	handleReset: null,
	addFooter: function() { return E('div'); }
});
