'use strict';
'require view';
'require request';
'require ui';
'require nodemanager.common as nm';

return view.extend({
	proxies: [],
	status: null,
	schemas: {},

	load: function() {
		return nm.call('load').then(function(resp) {
			return (resp && resp.ok) ? resp.data : {};
		});
	},

	render: function(data) {
		var self = this;
		self.proxies = data.proxies || [];
		self.status = data.status || {};
		self.schemas = data.schemas || {};

		var view = E('div', {'class': 'cbi-map'}, [
			E('h2', {}, _('Proxy Nodes')),
			nm.renderStatusBar(self.status),
			self.renderToolbar(),
			self.renderTable()
		]);

		return view;
	},

	renderToolbar: function() {
		var self = this;
		var running = self.status && self.status.running;

		return E('div', {
			'style': 'display:flex;gap:8px;margin-bottom:16px;flex-wrap:wrap;'
		}, [
			E('button', {
				'class': 'cbi-button cbi-button-add',
				'click': function() { self.addRow(); }
			}, '➕ ' + _('Add')),
			E('button', {
				'class': 'cbi-button',
				'click': function() { self.showImportModal(); }
			}, '📥 ' + _('Import')),
			E('button', {
				'class': 'cbi-button',
				'click': function() { self.handleExport(); }
			}, '📤 ' + _('Export')),
			E('button', {
				'class': 'cbi-button',
				'disabled': !running ? '' : null,
				'title': !running ? _('nikki is not running') : '',
				'click': function(ev) { self.testAll(ev.target); }
			}, '⚡ ' + _('Test All')),
			E('button', {
				'class': 'cbi-button cbi-button-save',
				'id': 'nm-save-btn',
				'click': function(ev) { self.handleSave(ev.target); }
			}, '💾 ' + _('Save'))
		]);
	},

	renderTable: function() {
		var self = this;
		var running = self.status && self.status.running;

		var iStyle = 'width:100%;box-sizing:border-box;overflow:hidden;text-overflow:ellipsis;';

		var thead = E('tr', {'class': 'tr table-titles'}, [
			E('th', {'class': 'th', 'style': 'width:24px'}, '☰'),
			E('th', {'class': 'th', 'style': 'width:60px'}, _('Type')),
			E('th', {'class': 'th', 'style': 'width:12%'}, _('Name')),
			E('th', {'class': 'th'}, _('Server')),
			E('th', {'class': 'th', 'style': 'width:55px'}, _('Port')),
			E('th', {'class': 'th', 'style': 'width:10%'}, _('Username')),
			E('th', {'class': 'th', 'style': 'width:10%'}, _('Password')),
			E('th', {'class': 'th', 'style': 'width:15%'}, _('Bind IPs')),
			E('th', {'class': 'th', 'style': 'width:45px'}, _('Delay')),
			E('th', {'class': 'th', 'style': 'width:50px'}, _('Action'))
		]);

		var tbody = E('tbody', {'id': 'nm-proxy-body'});

		for (var i = 0; i < self.proxies.length; i++) {
			tbody.appendChild(self.createRow(self.proxies[i], running));
		}

		self.initDragDrop(tbody);

		return E('table', {
			'class': 'table cbi-section-table',
			'id': 'nm-proxy-table',
			'style': 'table-layout:fixed;width:100%;'
		}, [
			E('thead', {}, [thead]),
			tbody
		]);
	},

	createRow: function(p, running) {
		var self = this;
		p = p || {name: '', type: 'socks5', server: '', port: '', username: '', password: '', bindips: []};

		var iS = 'width:100%;box-sizing:border-box;';

		var typeSelect = E('select', {
			'class': 'cbi-input-select',
			'data-field': 'type',
			'style': iS
		}, [
			E('option', {'value': 'socks5', 'selected': p.type === 'socks5' ? '' : null}, 's5'),
			E('option', {'value': 'http', 'selected': p.type === 'http' ? '' : null}, 'http')
		]);

		var passInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'password',
			'data-field': 'password',
			'value': p.password || '',
			'style': 'width:calc(100% - 20px);box-sizing:border-box;display:inline-block;'
		});

		var passToggle = E('span', {
			'style': 'cursor:pointer;margin-left:2px;user-select:none;font-size:12px;',
			'click': function() {
				var inp = this.previousElementSibling;
				inp.type = inp.type === 'password' ? 'text' : 'password';
				this.textContent = inp.type === 'password' ? '👁' : '🔒';
			}
		}, '👁');

		var delayCell = E('td', {'class': 'td', 'data-field': 'delay', 'style': 'text-align:center;overflow:hidden;'}, [
			nm.delayBadge(null)
		]);

		var testBtn = E('button', {
			'class': 'cbi-button',
			'style': 'padding:1px 4px;font-size:11px;margin-right:2px;',
			'disabled': !running ? '' : null,
			'title': _('Test connectivity'),
			'click': function(ev) { self.testOne(ev.target); }
		}, '🔍');

		var delBtn = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'style': 'padding:1px 4px;font-size:11px;',
			'click': function(ev) {
				if (confirm(_('Delete this row?'))) {
					ev.target.closest('tr').remove();
				}
			}
		}, '✕');

		var tdS = 'overflow:hidden;text-overflow:ellipsis;';

		return E('tr', {'class': 'tr', 'draggable': 'true'}, [
			E('td', {'class': 'td', 'style': 'cursor:grab;text-align:center;'}, '☰'),
			E('td', {'class': 'td', 'style': tdS}, [typeSelect]),
			E('td', {'class': 'td', 'style': tdS}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'name', 'value': p.name, 'style': iS, 'required': ''})
			]),
			E('td', {'class': 'td', 'style': tdS}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'server', 'value': p.server, 'style': iS, 'required': ''})
			]),
			E('td', {'class': 'td', 'style': tdS}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'port', 'value': p.port || '', 'style': iS, 'required': ''})
			]),
			E('td', {'class': 'td', 'style': tdS}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'username', 'value': p.username || '', 'style': iS})
			]),
			E('td', {'class': 'td', 'style': tdS}, [passInput, passToggle]),
			E('td', {'class': 'td', 'style': tdS}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'bindips', 'value': (p.bindips || []).join(', '), 'style': iS, 'placeholder': '192.168.8.101'})
			]),
			delayCell,
			E('td', {'class': 'td', 'style': 'white-space:nowrap;text-align:center;'}, [testBtn, delBtn])
		]);
	},

	addRow: function() {
		var tbody = document.getElementById('nm-proxy-body');
		var running = this.status && this.status.running;
		var tr = this.createRow(null, running);
		tbody.appendChild(tr);
		tr.querySelector('[data-field="name"]').focus();
	},

	collectRows: function() {
		var rows = document.querySelectorAll('#nm-proxy-body tr');
		var list = [];
		for (var i = 0; i < rows.length; i++) {
			var tr = rows[i];
			var get = function(field) {
				var el = tr.querySelector('[data-field="' + field + '"]');
				return el ? el.value : '';
			};
			var bindStr = get('bindips');
			var bindips = bindStr ? bindStr.split(/[,\s]+/).filter(function(s) { return s; }) : [];
			list.push({
				type: get('type'),
				name: get('name'),
				server: get('server'),
				port: parseInt(get('port'), 10) || 0,
				username: get('username'),
				password: get('password'),
				bindips: bindips
			});
		}
		return list;
	},

	handleSave: function(btn) {
		var self = this;
		var list = self.collectRows();
		btn.disabled = true;
		btn.textContent = _('Saving...');
		nm.call('save_proxies', {proxies: list})
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

	// ── Import ──────────────────────────────────────
	showImportModal: function() {
		var self = this;
		var textarea = E('textarea', {
			'style': 'width:100%;height:200px;font-family:monospace;font-size:12px;',
			'placeholder': _('Paste proxies here (JSON / YAML / URL / TXT)...\n\nExamples:\nsocks5://user:pass@1.2.3.4:1080#Name\n1.2.3.4:1080 # Name\n[{"name":"HK","type":"socks5","server":"1.2.3.4","port":1080}]')
		});

		var fileInput = E('input', {
			'type': 'file',
			'accept': '.json,.txt,.yaml,.yml',
			'style': 'margin-top:8px;',
			'change': function(ev) {
				var file = ev.target.files[0];
				if (!file) return;
				var reader = new FileReader();
				reader.onload = function(e) { textarea.value = e.target.result; };
				reader.readAsText(file);
			}
		});

		var modeSelect = E('select', {'style': 'margin-top:8px;'}, [
			E('option', {'value': 'append'}, _('Append to existing')),
			E('option', {'value': 'replace'}, _('Replace existing'))
		]);

		ui.showModal(_('Import Proxy Nodes'), [
			E('div', {}, [
				E('p', {}, _('Paste text or select a file. Format is auto-detected.')),
				textarea,
				E('div', {'style': 'display:flex;gap:12px;align-items:center;margin-top:8px;'}, [
					fileInput,
					modeSelect
				])
			]),
			E('div', {'class': 'right', 'style': 'margin-top:16px;'}, [
				E('button', {
					'class': 'cbi-button',
					'click': ui.hideModal
				}, _('Cancel')),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'style': 'margin-left:8px;',
					'click': function(ev) {
						var text = textarea.value;
						var mode = modeSelect.value;
						if (!text.trim()) {
							alert(_('Please paste or select content'));
							return;
						}
						ev.target.disabled = true;
						ev.target.textContent = _('Parsing...');
						nm.call('import', {text: text})
							.then(function(resp) {
								if (resp && resp.ok && resp.data) {
									self.applyImport(resp.data, mode);
									ui.hideModal();
									ui.addNotification(null,
										E('p', _('Imported %d nodes').format(resp.data.length)), 'info');
								} else {
									alert((resp && resp.err) || _('Import failed'));
								}
							})
							.catch(function(e) { alert(_('Error: ') + e.message); })
							.finally(function() {
								ev.target.disabled = false;
								ev.target.textContent = _('Import');
							});
					}
				}, _('Import'))
			])
		]);
	},

	applyImport: function(nodes, mode) {
		var tbody = document.getElementById('nm-proxy-body');
		var running = this.status && this.status.running;
		if (mode === 'replace') {
			while (tbody.firstChild) tbody.removeChild(tbody.firstChild);
		}
		for (var i = 0; i < nodes.length; i++) {
			tbody.appendChild(this.createRow(nodes[i], running));
		}
	},

	// ── Export ──────────────────────────────────────
	handleExport: function() {
		var list = this.collectRows().map(function(p) {
			return {name: p.name, type: p.type, server: p.server,
				port: p.port, username: p.username, password: p.password};
		});
		var blob = new Blob([JSON.stringify(list, null, 2)], {type: 'application/json'});
		var a = document.createElement('a');
		a.href = URL.createObjectURL(blob);
		a.download = 'nodemanager-proxies.json';
		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
	},

	// ── Test Proxy ─────────────────────────────────
	testOne: function(btn) {
		var tr = btn.closest('tr');
		var name = tr.querySelector('[data-field="name"]').value;
		var delayCell = tr.querySelector('[data-field="delay"]');
		if (!name) return;

		delayCell.textContent = '';
		delayCell.appendChild(E('span', {'style': 'color:#868e96'}, '⏳'));
		btn.disabled = true;

		nm.testProxy(name)
			.then(function(resp) {
				delayCell.textContent = '';
				if (resp && resp.ok && resp.data) {
					delayCell.appendChild(nm.delayBadge(resp.data.delay));
				} else {
					delayCell.appendChild(E('span', {'style': 'color:#ff6b6b;font-size:11px'},
						(resp && resp.err) || _('Timeout')));
				}
			})
			.catch(function() {
				delayCell.textContent = '';
				delayCell.appendChild(E('span', {'style': 'color:#ff6b6b'}, _('Error')));
			})
			.finally(function() { btn.disabled = false; });
	},

	testAll: function(btn) {
		var self = this;
		var rows = document.querySelectorAll('#nm-proxy-body tr');
		if (!rows.length) return;

		btn.disabled = true;
		var total = rows.length;
		var done = 0;
		btn.textContent = '⚡ 0/' + total;

		var queue = Array.prototype.slice.call(rows);
		function next() {
			if (!queue.length) {
				btn.disabled = false;
				btn.textContent = '⚡ ' + _('Test All');
				return;
			}
			var tr = queue.shift();
			var testBtn = tr.querySelector('.cbi-button[title]');
			if (testBtn) {
				self.testOne(testBtn);
			}
			done++;
			btn.textContent = '⚡ ' + done + '/' + total;
			window.setTimeout(next, 300);
		}
		next();
	},

	// ── Drag & Drop ────────────────────────────────
	initDragDrop: function(tbody) {
		var dragRow = null;

		tbody.addEventListener('dragstart', function(e) {
			dragRow = e.target.closest('tr');
			if (dragRow) {
				dragRow.style.opacity = '0.4';
				e.dataTransfer.effectAllowed = 'move';
			}
		});

		tbody.addEventListener('dragover', function(e) {
			e.preventDefault();
			e.dataTransfer.dropEffect = 'move';
			var target = e.target.closest('tr');
			if (target && target !== dragRow && target.parentNode === tbody) {
				var rect = target.getBoundingClientRect();
				var mid = rect.top + rect.height / 2;
				if (e.clientY < mid) {
					tbody.insertBefore(dragRow, target);
				} else {
					tbody.insertBefore(dragRow, target.nextSibling);
				}
			}
		});

		tbody.addEventListener('dragend', function() {
			if (dragRow) {
				dragRow.style.opacity = '1';
				dragRow = null;
			}
		});
	},

	handleSaveApply: null,
	handleReset: null
});
