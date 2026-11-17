// gk_people, actor_records: who is registering at a shared computer.
// The field in the issue form searches active internal persons by name as one types; a choice fills in the hidden
// person id and shows the name with a button to change it. Delegated from the document, so it keeps working when
// core re-renders the form (tracker or status changed). The names found are GK GUI Stuff's pills (GkGui.pill), the
// person's id and name on the pill's button (data-gk-people-actor-id, data-gk-people-actor-name).
// A minute before the choice at the computer runs out the page warns with GK GUI Stuff's notice and Förläng, which
// holds the choice longer when the setting allows it, else (or when it has already run out) opens Vem är du?. The
// minutes left in the top band's part count down. Plain DOM, no jQuery.
// A person whose account some other user may not see has records' mark after the name: the server draws it with
// records' helper (mark, HTML) and the script only puts it in.
(function () {
  if (window.GkPeopleActor) return;
  window.GkPeopleActor = true;
  var timer = null;

  function box(el) { return el && el.closest ? el.closest('.gk-people-actor') : null; }

  // records' mark as the server drew it, or nothing
  function mark(html) {
    if (!html) return null;
    var t = document.createElement('template');
    t.innerHTML = html;
    return t.content.querySelector('.gk-records-restricted');
  }

  function show(root, list) {
    var ul = root.querySelector('.gk-people-actor-found');
    ul.innerHTML = '';
    if (!list.length) {
      var li = document.createElement('span');
      li.className = 'gk-people-muted';
      li.textContent = root.getAttribute('data-none') || '';
      ul.appendChild(li);
    }
    list.forEach(function (p) {
      var li = document.createElement('span');
      li.className = 'gk-people-actor-hit';
      li.appendChild(window.GkGui.pill({ text: p.name, note: p.title || null,
                                         button: { data: { 'gk-people-actor-id': p.id, 'gk-people-actor-name': p.name } } }));
      var m = mark(p.mark);
      if (m) li.appendChild(m);
      ul.appendChild(li);
    });
    ul.hidden = false;
  }

  function search(root) {
    var q = root.querySelector('.gk-people-actor-q');
    var ul = root.querySelector('.gk-people-actor-found');
    var term = q.value.trim();
    if (term.length < 2) { ul.hidden = true; ul.innerHTML = ''; return; }
    var url = root.getAttribute('data-search-url');
    fetch(url + (url.indexOf('?') >= 0 ? '&' : '?') + 'q=' + encodeURIComponent(term),
      { credentials: 'same-origin', headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (list) { if (q.value.trim() === term) show(root, list); })
      .catch(function () {});
  }

  function choose(root, id, name, pick) {
    root.querySelector('.gk-people-actor-id').value = id;
    var shown = root.querySelector('.gk-people-actor-name');
    shown.textContent = name;
    var hit = pick ? pick.closest('.gk-people-actor-hit') : null, m = hit ? hit.querySelector('.gk-records-restricted') : null;
    if (m) shown.appendChild(m.cloneNode(true));
    root.querySelector('.gk-people-actor-chosen').hidden = false;
    var q = root.querySelector('.gk-people-actor-q');
    q.value = '';
    q.hidden = true;
    var ul = root.querySelector('.gk-people-actor-found');
    ul.hidden = true;
    ul.innerHTML = '';
  }

  document.addEventListener('input', function (e) {
    var root = box(e.target);
    if (!root || !e.target.classList.contains('gk-people-actor-q')) return;
    clearTimeout(timer);
    timer = setTimeout(function () { search(root); }, 200);
  });

  // The badge field: a reader in keyboard mode ends with Enter, which sends it (caught first, since other scripts on
  // the page may hold Enter back in fields)
  document.addEventListener('keydown', function (e) {
    var t = e.target;
    if (!t || t.id !== 'gk_people_badge' || e.key !== 'Enter') return;
    e.preventDefault();
    e.stopPropagation();
    if (t.value.trim() && t.form) t.form.submit();
  }, true);

  // Enter in the search chooses the only hit, and never sends the form half filled in
  document.addEventListener('keydown', function (e) {
    var root = box(e.target);
    if (!root || !e.target.classList.contains('gk-people-actor-q') || e.key !== 'Enter') return;
    e.preventDefault();
    var picks = root.querySelectorAll('button[data-gk-people-actor-id]');
    if (picks.length === 1) choose(root, picks[0].getAttribute('data-gk-people-actor-id'), picks[0].getAttribute('data-gk-people-actor-name'), picks[0]);
  });

  document.addEventListener('click', function (e) {
    var pick = e.target.closest && e.target.closest('button[data-gk-people-actor-id]');
    var change = e.target.closest && e.target.closest('.gk-people-actor-change');
    var root = box(pick || change);
    if (!root) return;
    e.preventDefault();
    if (pick) { choose(root, pick.getAttribute('data-gk-people-actor-id'), pick.getAttribute('data-gk-people-actor-name'), pick); return; }
    root.querySelector('.gk-people-actor-id').value = '';
    root.querySelector('.gk-people-actor-chosen').hidden = true;
    var q = root.querySelector('.gk-people-actor-q');
    q.hidden = false;
    q.focus();
  });

  // ---------------------------------------------------------------- a minute left: Förläng
  var warnTimer = null;

  function csrf() { var m = document.querySelector('meta[name="csrf-token"]'); return m ? m.getAttribute('content') : ''; }
  function toWho(bar) { window.location.href = bar.getAttribute('data-who-url') || '/'; }

  function prolong(bar) {
    var url = bar.getAttribute('data-prolong-url');
    if (!url) { toWho(bar); return; } // the setting does not allow it: say who one is again
    fetch(url, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest', 'X-CSRF-Token': csrf() }
    }).then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }).then(function (j) {
      if (j && j.ok) { arm(bar, j.seconds); return; }
      toWho(bar);
    }).catch(function () { toWho(bar); });
  }

  function warn(bar) {
    var text = bar.getAttribute('data-warn') || '';
    var label = bar.getAttribute('data-prolong') || '';
    window.GkGui.notice.show({ level: 'warning', life: 'sticky', text: text, buttons: [{ label: label, action: function () { prolong(bar); } }] });
  }

  // the minutes left in the top band's part, counted down from when the page came (or Förläng answered)
  var countTimer = null;
  function count(bar, s) {
    clearInterval(countTimer);
    var el = bar.querySelector('.gk-people-actor-left');
    if (!el) return;
    var until = Date.now() + s * 1000;
    var show = function () { el.textContent = String(Math.max(Math.ceil((until - Date.now()) / 60000), 0)); };
    show();
    countTimer = setInterval(show, 15000);
  }

  function arm(bar, seconds) {
    clearTimeout(warnTimer);
    var s = parseInt(seconds, 10);
    if (!(s > 0)) return;
    count(bar, s);
    warnTimer = setTimeout(function () { warn(bar); }, Math.max(s - 60, 0) * 1000);
  }

  function initBar() {
    var bar = document.querySelector('.gk-people-actor-bar[data-seconds-left]');
    if (bar) arm(bar, bar.getAttribute('data-seconds-left'));
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initBar); else initBar();
})();
