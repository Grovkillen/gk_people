// The quick line (gk_people_quick/_box): Enter saves at once and empties the field for the next; the lines wait in a
// queue and are sent one at a time, so typing never waits for the server. The reading of the line (the server's own
// rules, quick/preview) shows while typing and is never asked for before a save. Several pasted lines are one post
// each. A saved row lists its parts; a click on a part gives the fields to move it to. Plain script, no jQuery; without
// it the form posts the line.
// GK GUI Stuff draws the parts (GkGui.pill) and says Sparar, Sparat and Inte sparat: every row is a save rail built in
// the script (GkGui.save.rail), first to the save's address (answered { rows: [...] }), then, once saved, to the
// row's own address for moving a part (answered { row: ... }). The row's body is drawn again when an answer comes; the
// rail's bar and word stay.
(function () {
  'use strict';

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function start(form) {
    if (form.getAttribute('data-gk-people-quick-ready')) return;
    form.setAttribute('data-gk-people-quick-ready', '1');
    var cfg;
    try { cfg = JSON.parse(form.getAttribute('data-gk-people-quick')); } catch (e) { return; }
    var T = cfg.texts || {};
    var input = form.querySelector('.gk-people-quick-input');
    var prev = form.querySelector('.gk-people-quick-preview');
    var rows = form.querySelector('.gk-people-quick-rows');
    if (!input || !prev || !rows) return;
    var G = window.GkGui;
    var queue = [];
    var busy = false;
    var timer = null;
    var asked = 0;

    // A part of the line as GK GUI Stuff's pill: the text, the field's name as its note; an uncertain part dashed with
    // its tip, the word for an unsure line in the role warning. button: the pill is one button (a part to move)
    function chip(p, button) {
      var o = { text: p.text + (p.uncertain ? ' ?' : ''), note: p.label, dashed: !!p.uncertain,
                role: p.field === 'unsure' ? 'warning' : null, className: 'gk-people-quick-f-' + p.field };
      if (button) o.as = 'button';
      var c = G.pill(o);
      if (button) c.title = T.move || '';
      else if (p.uncertain) c.title = T.uncertain || '';
      return c;
    }

    // ---------------------------------------------------------------- the reading while typing
    function showPreview(j) {
      prev.innerHTML = '';
      (j.parts || []).forEach(function (p) { prev.appendChild(chip(p, false)); });
      // the step the line gives, in the words of the place it lands on; the tip when "?" fell back there
      if (j.status_label) prev.appendChild(el('span', 'badge badge-private gk-people-badge', j.status_label));
      if (j.tip) prev.appendChild(el('span', 'gk-people-muted gk-people-quick-tip', ' ' + j.tip));
      if (j.organization) prev.appendChild(el('span', 'gk-people-muted', ' ' + (j.organization.known ? T.known_org : T.new_org)));
    }

    function ask() {
      var v = input.value.trim();
      var n = ++asked;
      if (!v) { prev.innerHTML = ''; return; }
      var url = cfg.preview + '?line=' + encodeURIComponent(v) + '&context=' + encodeURIComponent(cfg.context || '');
      fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
        .then(function (r) { return r.ok ? r.json() : null; })
        .then(function (j) { if (j && n === asked && input.value.trim() === v) showPreview(j); })
        .catch(function () { /* the reading is only a help */ });
    }

    input.addEventListener('input', function () {
      clearTimeout(timer);
      timer = setTimeout(ask, 250);
    });

    // ---------------------------------------------------------------- saving, one line at a time
    // the row's body, drawn again with every answer; the rail's bar and word are the row's own children after it
    function body(li) {
      var b = li.querySelector(':scope > .gk-people-quick-row-body');
      if (!b) { b = el('span', 'gk-people-quick-row-body'); li.insertBefore(b, li.firstChild); }
      b.innerHTML = '';
      return b;
    }

    function enqueue(text) {
      String(text).split(/\r?\n/).map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; }).forEach(function (line) {
        var li = el('li', 'gk-people-quick-row');
        body(li).appendChild(el('span', 'gk-people-quick-line-text', line));
        rows.insertBefore(li, rows.firstChild);
        queue.push({ line: line, li: li, rail: G.save.rail(li, cfg.save, { method: 'POST' }) });
      });
      next();
    }

    function next() {
      if (busy || queue.length === 0) return;
      busy = true;
      var item = queue.shift();
      item.rail.send({ line: item.line, context: cfg.context || '' }).then(function (j) {
        drawRow(item.li, (j.rows || [])[0] || {});
      }, function () {
        failRow(item.li, item.line);
      }).then(function () {
        busy = false;
        next();
      });
    }

    // the rail says Inte sparat with the server's errors; the line stays in the row, and back in the field when it is
    // empty, so it can be put right and saved again
    function failRow(li, line) {
      body(li).appendChild(el('span', 'gk-people-quick-line-text', line));
      if (!input.value) input.value = line;
    }

    function drawRow(li, r) {
      var b = body(li);
      var a = el('a', 'gk-people-quick-name', r.name);
      a.href = r.url;
      b.appendChild(a);
      if (r.organization) {
        b.appendChild(document.createTextNode(', '));
        var o = el('a', null, r.organization.name);
        o.href = r.organization.url;
        b.appendChild(o);
      }
      if (r.status) b.appendChild(el('span', 'badge badge-private gk-people-badge', r.status));
      if (r.tip) b.appendChild(el('span', 'gk-people-muted gk-people-quick-tip', ' ' + r.tip));
      var parts = el('span', 'gk-people-quick-parts');
      (r.parts || []).forEach(function (p) {
        var canMove = r.movable && r.move_url && p.field !== 'unsure';
        var c = chip(p, canMove);
        if (canMove) c.addEventListener('click', function () { chooseField(li, r, p, c); });
        parts.appendChild(c);
      });
      b.appendChild(parts);
    }

    // A part to another field: the fields as a list in its place; the choice is saved at once through the row's rail,
    // leaving it is no change
    function chooseField(li, r, p, c) {
      var sel = el('select', 'gk-people-quick-move');
      sel.setAttribute('aria-label', T.move || '');
      (cfg.fields || []).forEach(function (f) {
        var o = el('option', null, f[1]);
        o.value = f[0];
        if (f[0] === p.field) o.selected = true;
        sel.appendChild(o);
      });
      c.parentNode.replaceChild(sel, c);
      sel.focus();
      var done = false;
      function finish() {
        if (done) return;
        done = true;
        var to = sel.value;
        if (!to || to === p.field) { drawRow(li, r); return; }
        G.save.rail(li, r.move_url, { method: 'POST' }).send({ part: p.i, to: to }).then(function (j) {
          drawRow(li, j.row || r);
        }, function () { drawRow(li, r); });
      }
      sel.addEventListener('change', finish);
      sel.addEventListener('blur', finish);
      sel.addEventListener('keydown', function (ev) {
        if (ev.key === 'Escape') { sel.value = p.field; finish(); }
      });
    }

    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var v = input.value;
      input.value = '';
      prev.innerHTML = '';
      asked++;
      enqueue(v);
      input.focus();
    });

    // Several lines pasted: every line its own post (a text field would make them one)
    input.addEventListener('paste', function (ev) {
      var data = ev.clipboardData || window.clipboardData;
      var text = data ? data.getData('text') : '';
      if (!text || !/\r?\n/.test(text.trim())) return;
      ev.preventDefault();
      var before = input.value;
      input.value = '';
      prev.innerHTML = '';
      asked++;
      enqueue((before ? before + '\n' : '') + text);
    });
  }

  function startAll() {
    document.querySelectorAll('form[data-gk-people-quick]').forEach(start);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startAll); else startAll();
})();
