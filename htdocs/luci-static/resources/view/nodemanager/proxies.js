'use strict';
'require view';
'require request';
'require ui';
'require nodemanager.common as nm';

return view.extend({
	proxies: [],
	status: null,
	schemas: {},
	currentPage: 1,
	pageSize: 50,

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
			self.renderTable(),
			self.renderPagination()
		]);

		window.setTimeout(function() { self.refreshPage(); }, 0);
		return view;
	},

	renderToolbar: function() {
		var self = this;
		var running = self.status && self.status.running;

		var batchDelBtn = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'id': 'nm-batch-del',
			'disabled': '',
			'click': function(ev) { self.handleBatchDelete(ev.target); }
		}, '🗑️ ' + _('Batch Delete'));

		return E('div', {
			'style': 'display:flex;gap:8px;margin-bottom:16px;flex-wrap:wrap;align-items:center;'
		}, [
			E('button', {
				'class': 'cbi-button cbi-button-add',
				'click': function() { self.addRow(); }
			}, '➕ ' + _('Add')),
			batchDelBtn,
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

		var iStyle = 'width:100%;box-sizing:border-box;overflow:hidden;text-overflow:ellipsis;';

		var thS = 'text-align:center;';
		var selectAllCb = E('input', {
			'type': 'checkbox',
			'id': 'nm-select-all',
			'title': _('Select All'),
			'change': function() { self.togglePageSelect(this.checked); }
		});
		var thead = E('tr', {'class': 'tr table-titles'}, [
			E('th', {'class': 'th', 'style': thS + 'width:24px'}, [selectAllCb]),
			E('th', {'class': 'th', 'style': thS + 'width:24px'}, '☰'),
			E('th', {'class': 'th', 'style': thS + 'width:12%'}, _('Name')),
			E('th', {'class': 'th', 'style': thS + 'width:15ch'}, _('Server')),
			E('th', {'class': 'th', 'style': thS + 'width:6ch'}, _('Port')),
			E('th', {'class': 'th', 'style': thS + 'width:12%'}, _('Username')),
			E('th', {'class': 'th', 'style': thS + 'width:12%'}, _('Password')),
			E('th', {'class': 'th', 'style': thS + 'width:15ch'}, _('Bind IPs')),
			E('th', {'class': 'th', 'style': thS + 'width:45px'}, _('Delay')),
			E('th', {'class': 'th', 'style': thS + 'width:60px'}, _('Action'))
		]);

		var tbody = E('tbody', {'id': 'nm-proxy-body'});

		var running = self.status && self.status.running;
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

	// ── Pagination ──────────────────────────────────
	renderPagination: function() {
		var self = this;

		var pageSizeSelect = E('select', {
			'id': 'nm-page-size',
			'style': 'margin:0 8px;',
			'change': function(ev) {
				self.pageSize = parseInt(ev.target.value, 10);
				self.currentPage = 1;
				self.refreshPage();
			}
		}, [10, 20, 50, 100].map(function(n) {
			return E('option', {'value': n, 'selected': n === self.pageSize ? '' : null}, n + _(' / page'));
		}));

		return E('div', {
			'id': 'nm-pagination',
			'style': 'display:flex;align-items:center;justify-content:center;gap:8px;margin-top:12px;padding:8px 0;'
		}, [
			E('button', {
				'class': 'cbi-button',
				'id': 'nm-page-prev',
				'style': 'padding:2px 10px;',
				'click': function() { self.currentPage--; self.refreshPage(); }
			}, '◀'),
			E('span', {'id': 'nm-page-info', 'style': 'font-size:13px;min-width:80px;text-align:center;'}, ''),
			E('button', {
				'class': 'cbi-button',
				'id': 'nm-page-next',
				'style': 'padding:2px 10px;',
				'click': function() { self.currentPage++; self.refreshPage(); }
			}, '▶'),
			pageSizeSelect
		]);
	},

	refreshPage: function() {
		var tbody = document.getElementById('nm-proxy-body');
		if (!tbody) return;

		var rows = tbody.querySelectorAll('tr');
		var total = rows.length;
		var totalPages = Math.max(1, Math.ceil(total / this.pageSize));

		if (this.currentPage > totalPages) this.currentPage = totalPages;
		if (this.currentPage < 1) this.currentPage = 1;

		var start = (this.currentPage - 1) * this.pageSize;
		var end = start + this.pageSize;

		for (var i = 0; i < rows.length; i++) {
			rows[i].style.display = (i >= start && i < end) ? '' : 'none';
		}

		var info = document.getElementById('nm-page-info');
		if (info) info.textContent = this.currentPage + ' / ' + totalPages + ' (' + total + ')';

		var prev = document.getElementById('nm-page-prev');
		var next = document.getElementById('nm-page-next');
		if (prev) prev.disabled = this.currentPage <= 1;
		if (next) next.disabled = this.currentPage >= totalPages;

		// Reset select-all on page change
		var all = document.getElementById('nm-select-all');
		if (all) all.checked = false;
		this.updateBatchState();
	},

	createRow: function(p, running) {
		var self = this;
		p = p || {name: '', type: 'socks5', server: '', port: '', username: '', password: '', bindips: []};

		var iS = 'width:100%;box-sizing:border-box;';

		var passInput = E('input', {
			'class': 'cbi-input-text',
			'type': 'password',
			'data-field': 'password',
			'value': p.password || '',
			'style': 'width:100%;box-sizing:border-box;padding-right:20px;'
		});

		var passToggle = E('span', {
			'style': 'position:absolute;right:4px;top:50%;transform:translateY(-50%);cursor:pointer;user-select:none;font-size:12px;z-index:1;',
			'click': function() {
				var inp = this.parentNode.querySelector('input');
				inp.type = inp.type === 'password' ? 'text' : 'password';
				this.textContent = inp.type === 'password' ? '👁' : '🔒';
			}
		}, '👁');

		var passWrap = E('div', {'style': 'position:relative;width:100%;'}, [passInput, passToggle]);
		var passCell = E('td', {'class': 'td', 'style': tdS}, [passWrap]);

		var delayCell = E('td', {'class': 'td', 'data-field': 'delay', 'style': 'text-align:center;overflow:hidden;'}, [
			nm.delayBadge(null)
		]);

		var btnS = 'width:24px;height:24px;padding:0;font-size:12px;line-height:24px;text-align:center;';

		var testBtn = E('button', {
			'class': 'cbi-button',
			'style': btnS,
			'disabled': !running ? '' : null,
			'title': _('Test connectivity'),
			'click': function(ev) { self.testOne(ev.target); }
		}, '⚡');

		var delBtn = E('button', {
			'class': 'cbi-button cbi-button-remove',
			'style': btnS,
			'click': function(ev) {
				if (confirm(_('Delete this row?'))) {
					ev.target.closest('tr').remove();
					self.refreshPage();
				}
			}
		}, '🗑️');

		var tdS = 'overflow:hidden;text-overflow:ellipsis;';

		// Hidden type field to preserve the value
		var typeHidden = E('input', {'type': 'hidden', 'data-field': 'type', 'value': p.type || 'socks5'});

		var dragHandle = E('td', {'class': 'td', 'style': 'cursor:grab;text-align:center;user-select:none;'}, ['☰', typeHidden]);
		// Only the ☰ handle triggers drag, not the entire row (so inputs remain selectable)
		dragHandle.addEventListener('mousedown', function() {
			this.closest('tr').setAttribute('draggable', 'true');
		});
		dragHandle.addEventListener('mouseup', function() {
			this.closest('tr').removeAttribute('draggable');
		});

		return E('tr', {'class': 'tr'}, [
			E('td', {'class': 'td', 'style': 'text-align:center;'}, [
				E('input', {
					'type': 'checkbox',
					'class': 'nm-row-cb',
					'change': function() { self.updateBatchState(); }
				})
			]),
			dragHandle,
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
			passCell,
			E('td', {'class': 'td', 'style': tdS}, [
				E('input', {'class': 'cbi-input-text', 'data-field': 'bindips', 'value': (p.bindips || []).join(', '), 'style': iS, 'placeholder': '192.168.5.101'})
			]),
			delayCell,
			E('td', {'class': 'td', 'style': 'white-space:nowrap;text-align:center;display:flex;gap:4px;justify-content:center;align-items:center;'}, [testBtn, delBtn])
		]);
	},

	addRow: function() {
		var tbody = document.getElementById('nm-proxy-body');
		var running = this.status && this.status.running;
		var tr = this.createRow(null, running);
		tbody.appendChild(tr);
		// Jump to last page
		var total = tbody.querySelectorAll('tr').length;
		this.currentPage = Math.ceil(total / this.pageSize);
		this.refreshPage();
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
		this.currentPage = 1;
		this.refreshPage();
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

	updateBatchState: function() {
		var checked = document.querySelectorAll('#nm-proxy-body .nm-row-cb:checked');
		var btn = document.getElementById('nm-batch-del');
		if (btn) {
			btn.disabled = checked.length === 0;
			btn.textContent = checked.length > 0
				? '🗑️ ' + _('Batch Delete') + ' (' + checked.length + ')'
				: '🗑️ ' + _('Batch Delete');
		}
		// Update select-all checkbox
		var all = document.getElementById('nm-select-all');
		if (all) {
			var visible = document.querySelectorAll('#nm-proxy-body tr[style=""] .nm-row-cb, #nm-proxy-body tr:not([style]) .nm-row-cb');
			var visChecked = 0;
			for (var i = 0; i < visible.length; i++) {
				if (visible[i].checked) visChecked++;
			}
			all.checked = visible.length > 0 && visChecked === visible.length;
			all.indeterminate = visChecked > 0 && visChecked < visible.length;
		}
	},

	togglePageSelect: function(checked) {
		var rows = document.querySelectorAll('#nm-proxy-body tr');
		var start = (this.currentPage - 1) * this.pageSize;
		var end = start + this.pageSize;
		for (var i = 0; i < rows.length; i++) {
			if (i >= start && i < end) {
				var cb = rows[i].querySelector('.nm-row-cb');
				if (cb) cb.checked = checked;
			}
		}
		this.updateBatchState();
	},

	handleBatchDelete: function(btn) {
		var checked = document.querySelectorAll('#nm-proxy-body .nm-row-cb:checked');
		if (!checked.length) return;
		if (!confirm(_('Delete %d selected nodes?').format(checked.length))) return;
		for (var i = checked.length - 1; i >= 0; i--) {
			checked[i].closest('tr').remove();
		}
		this.refreshPage();
		this.updateBatchState();
	},

	handleSaveApply: null,
	handleReset: null,
	addFooter: function() { return E('div'); }
});
