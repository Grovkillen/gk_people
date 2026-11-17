// gk_people, Stega upp (elevation).
// * The form opens in gui_stuff's surface (GkGui.surface, the one modal surface) over the page: from Stega upp… in
//   the account menu, and at once on the barrier page that a page needing admin sends to. It is fetched as a
//   fragment and sent as JSON; on success the page asked for is loaded, on failure the form comes back with the
//   message. Without gui_stuff or script nothing is intercepted and the page itself is the form.
// * A click on an earlier reason fills in the reason and goes to the password when it is still empty.
(function () {
  // loaded by the page and by the head hook: once is enough
  if (window.GkPeopleElevation) return;
  window.GkPeopleElevation = true;
  function surfaceReady() { return !!(window.GkGui && window.GkGui.surface && window.GkGui.surface.open); } // gk-u U13: a timing guard, not a fallback: this script may run before GK GUI Stuff's elements have put the surface on GkGui
  function withParam(url, key, value) { return url + (url.indexOf('?') >= 0 ? '&' : '?') + key + '=' + encodeURIComponent(value); }
  function hide(el, yes) { if (el) el.classList.toggle('gk-people-hidden', yes); }

  function bindForm(s) {
    var form = s.body.querySelector('#gk-people-elevate-form');
    if (!form) return;
    form.addEventListener('submit', function (e) { e.preventDefault(); send(s); });
    var pw = form.querySelector('#gk_people_password');
    if (pw) pw.focus();
  }

  function fill(s, html) {
    s.body.innerHTML = html;
    bindForm(s);
  }

  function send(s) {
    var form = s.body.querySelector('#gk-people-elevate-form');
    if (!form || s.busy) return;
    s.busy = true;
    fetch(form.getAttribute('action'), {
      method: 'POST', body: new FormData(form), credentials: 'same-origin',
      headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
    }).then(function (r) { return r.json(); }).then(function (j) {
      s.busy = false;
      if (j.ok) { window.location.href = j.redirect || window.location.href; return; }
      if (j.html) fill(s, j.html);
    }).catch(function () { s.busy = false; form.submit(); }); // the page as before if anything goes wrong
  }

  // Open the surface with the form fetched from url; false when there is no surface (the caller then navigates).
  // opts: onClose, onOpened (the surface is up), onFail (the fragment could not be fetched; default: go to the page)
  function open(url, opts) {
    opts = opts || {};
    if (!surfaceReady()) return false;
    fetch(url, { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
      .then(function (html) {
        var wrap = document.createElement('div');
        wrap.innerHTML = html;
        var root = wrap.querySelector('.gk-people-elevate');
        var hasForm = !!wrap.querySelector('#gk-people-elevate-form');
        var footer = [{ label: (root && root.getAttribute('data-cancel')) || '×', role: 'cancel' }];
        var s = null;
        if (hasForm) footer.push({ label: (root && root.getAttribute('data-submit')) || 'OK', role: 'primary', action: function (sf) { send(sf); } });
        s = window.GkGui.surface.open({ title: (root && root.getAttribute('data-title')) || '', content: wrap, size: 'small', footer: footer, onClose: opts.onClose });
        s.body.classList.add('gk-people-elevate-surface');
        if (opts.onOpened) opts.onOpened(s);
        bindForm(s);
      })
      .catch(function () {
        if (opts.onFail) { opts.onFail(); return; }
        window.location.href = url.replace(/([?&])fragment=1&?/, '$1').replace(/[?&]$/, '');
      });
    return true;
  }

  document.addEventListener('click', function (e) {
    var t = e.target;
    // an earlier reason
    // (GK GUI Stuff's choice pills; the button carries the reason in data-gk-people-reason, GkGui.choose presses it)
    var chip = t.closest ? t.closest('button[data-gk-people-reason]') : null;
    if (chip) {
      e.preventDefault();
      var scope = chip.closest('.gk-people-elevate') || document;
      var reason = scope.querySelector('#gk_people_reason');
      if (!reason) return;
      reason.value = chip.getAttribute('data-gk-people-reason') || '';
      window.GkGui.choose(scope.querySelectorAll('button[data-gk-people-reason]'), chip);
      var pw = scope.querySelector('#gk_people_password');
      if (pw && pw.value === '') { pw.focus(); return; }
      var submit = scope.querySelector('.gk-people-elevate-submit') || document.querySelector('.gk-gui-stuff-btn-primary');
      if (submit) submit.focus();
      return;
    }
    // Stega upp… in the account menu (also the dimmed row, whose surface says why): over this page, back to it afterwards
    var link = t.closest ? t.closest('a.gk-people-step-up') : null;
    if (link && surfaceReady()) {
      e.preventDefault();
      open(withParam(withParam(link.getAttribute('href'), 'fragment', '1'), 'back_url', window.location.href));
      return;
    }
    // the button on the barrier page that opens it again
    if (t.closest && t.closest('.gk-people-elevate-open')) { e.preventDefault(); openOnPage(); }
  });

  // The barrier page: the form in the surface at once (the form on the page is taken away while the surface is up,
  // so that there is one of it); closed without stepping up, a line and a button remain. If the fragment cannot be
  // fetched the form on the page stays.
  var pageForm = null;
  function openOnPage() {
    var page = document.getElementById('gk-people-elevate-page');
    if (!page || page.getAttribute('data-auto-surface') !== '1') return;
    var reopen = document.getElementById('gk-people-elevate-reopen');
    open(page.getAttribute('data-fragment-url'), {
      onOpened: function () {
        if (!pageForm && page.firstElementChild) pageForm = page.removeChild(page.firstElementChild);
        hide(page, true); hide(reopen, true);
      },
      onClose: function () { hide(reopen, false); },
      onFail: function () { if (pageForm) page.appendChild(pageForm); hide(page, false); hide(reopen, true); }
    });
  }

  function start() { if (surfaceReady()) openOnPage(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
