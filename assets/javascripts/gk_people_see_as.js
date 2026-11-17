// gk_people, Se som (see_as).
// * Se som in the account menu opens the choice in gui_stuff's surface over the page (fetched as a fragment for the
//   path of this page, so that the choices belong to the place); a choice starts it and this page is shown again as
//   the one looked as. Search among all fills in as one types.
// * Förhandsvisa mejl in the box of the state in the top menu opens the mail preview in the surface.
// * The state itself (the line in the top menu, the ribbon and the frame) is gk_people_topmenu.js's.
// Without gui_stuff or script nothing is intercepted and the pages themselves do it.
(function () {
  if (window.GkPeopleSeeAs) return;
  window.GkPeopleSeeAs = true;
  function surfaceReady() { return !!(window.GkGui && window.GkGui.surface && window.GkGui.surface.open); } // gk-u U13: a timing guard, not a fallback: this script may run before GK GUI Stuff's elements have put the surface on GkGui
  function withParam(url, key, value) { return url + (url.indexOf('?') >= 0 ? '&' : '?') + key + '=' + encodeURIComponent(value); }
  function here() { return window.location.pathname + window.location.search; }

  function bindChooser(s) {
    var form = s.body.querySelector('#gk-people-see-as-form');
    if (!form) return;
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var btn = e.submitter;
      if (btn && btn.name === 'search') { search(s); return; }
      if (!btn || btn.name !== 'pick' || s.busy) return;
      s.busy = true;
      var data = new FormData(form);
      data.set('pick', btn.value);
      fetch(form.getAttribute('action'), { method: 'POST', body: data, credentials: 'same-origin',
        headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
        .then(function (r) { return r.json(); })
        .then(function (j) {
          s.busy = false;
          if (j.ok) { window.location.href = j.redirect || window.location.href; return; }
          if (j.html) { s.body.innerHTML = j.html; bindChooser(s); }
        })
        .catch(function () { s.busy = false; form.submit(); });
    });
    var q = form.querySelector('#gk_people_see_as_q');
    var timer = null;
    if (q) q.addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(function () { search(s); }, 250); });
  }

  function search(s) {
    var root = s.body.querySelector('.gk-people-see-as-choose');
    var q = s.body.querySelector('#gk_people_see_as_q');
    var out = s.body.querySelector('#gk-people-see-as-found');
    if (!root || !q || !out) return;
    if (q.value.trim().length < 2) { out.innerHTML = ''; return; }
    fetch(withParam(root.getAttribute('data-search-url'), 'q', q.value), { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
      .then(function (html) { out.innerHTML = html; })
      .catch(function () { out.innerHTML = ''; });
  }

  function open(url, rootSelector, size, after) {
    if (!surfaceReady()) return false;
    fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
      .then(function (html) {
        var wrap = document.createElement('div');
        wrap.innerHTML = html;
        var root = wrap.querySelector(rootSelector);
        var s = window.GkGui.surface.open({ title: (root && root.getAttribute('data-title')) || '', content: wrap, size: size,
          footer: [{ label: (root && root.getAttribute('data-cancel')) || '×', role: 'cancel' }] });
        s.body.classList.add('gk-people-see-as-surface');
        if (after) after(s);
      })
      .catch(function () { window.location.href = url.replace(/([?&])fragment=1&?/, '$1').replace(/[?&]$/, ''); });
    return true;
  }

  document.addEventListener('click', function (e) {
    var t = e.target;
    if (!t.closest) return;
    var link = t.closest('a.gk-people-see-as');
    if (link && surfaceReady()) {
      e.preventDefault();
      open(withParam(withParam(link.getAttribute('href'), 'fragment', '1'), 'path', here()), '.gk-people-see-as-choose', 'medium', bindChooser);
      return;
    }
    var mail = t.closest('a.gk-people-see-as-mail');
    if (mail && surfaceReady()) {
      e.preventDefault();
      open(withParam(mail.getAttribute('href'), 'fragment', '1'), '.gk-people-see-as-mail-preview', 'large');
    }
  });
})();
