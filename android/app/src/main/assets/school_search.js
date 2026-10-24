(function () {
  var sel = document.getElementById('customerSelect');
  if (!sel || sel.__searchable) return;
  var opts = [];
  for (var i = 0; i < sel.options.length; i++) {
    var o = sel.options[i];
    if (o.value) opts.push({ v: o.value, t: o.text.trim() });
  }
  if (opts.length < 2) { sel.__pending = (sel.__pending || 0) + 1; return; } // 等选项加载, 稍后重试
  sel.__searchable = true;

  // 隐藏原生 select(保留在表单中), 用搜索框代替
  sel.style.display = 'none';
  var parent = sel.parentNode;
  var box = document.createElement('input');
  box.setAttribute('readonly', 'readonly');
  box.placeholder = '🔍 点击搜索学校';
  box.style.cssText = 'width:100%;box-sizing:border-box;padding:12px;font-size:15px;' +
    'border:1px solid #eee;border-radius:8px;background:#f7f7f7;color:#333;';
  parent.insertBefore(box, sel);

  // 底部弹层: 搜索 + 列表
  var overlay = document.createElement('div');
  overlay.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;' +
    'background:rgba(0,0,0,.45);display:none;z-index:99999;';
  var panel = document.createElement('div');
  panel.style.cssText = 'position:absolute;left:0;right:0;bottom:0;top:12%;' +
    'background:#fff;border-radius:12px 12px 0 0;display:flex;flex-direction:column;overflow:hidden;';
  var search = document.createElement('input');
  search.placeholder = '输入学校名称关键字';
  search.style.cssText = 'margin:12px;padding:12px;font-size:16px;' +
    'border:1px solid #FFB830;border-radius:8px;outline:none;';
  var list = document.createElement('div');
  list.style.cssText = 'flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;';
  panel.appendChild(search);
  panel.appendChild(list);
  overlay.appendChild(panel);
  document.body.appendChild(overlay);

  function render(kw) {
    list.innerHTML = '';
    var k = (kw || '').trim().toLowerCase();
    var n = 0;
    for (var i = 0; i < opts.length && n < 80; i++) {
      var it = opts[i];
      if (k && it.t.toLowerCase().indexOf(k) < 0) continue;
      n++;
      var d = document.createElement('div');
      d.textContent = it.t;
      d.style.cssText = 'padding:14px 16px;border-bottom:1px solid #f2f2f2;font-size:15px;color:#333;';
      (function (item) {
        d.onclick = function () {
          sel.value = item.v;
          sel.dispatchEvent(new Event('change', { bubbles: true }));
          box.value = item.t;
          overlay.style.display = 'none';
        };
      })(it);
      list.appendChild(d);
    }
    if (n === 0) {
      list.innerHTML = '<div style="padding:24px;text-align:center;color:#999;">没有匹配的学校</div>';
    }
  }

  box.onclick = function () {
    overlay.style.display = 'block';
    search.value = '';
    render('');
    setTimeout(function () { search.focus(); }, 120);
  };
  overlay.onclick = function (e) { if (e.target === overlay) overlay.style.display = 'none'; };
  search.oninput = function () { render(search.value); };

  // 已选过则回显
  if (sel.value) {
    for (var j = 0; j < opts.length; j++) if (opts[j].v === sel.value) box.value = opts[j].t;
  }
})();
