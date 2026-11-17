/* gk_people name links: the chat program's icon after a person's name is the way to the program she is reached in
   (a contact scheme the administrator marked for the name), with a link to the page one came from. The name itself
   stays core's link to the account. A program that cannot take the page along gets its address copied when the
   icon is clicked. The lamp stays nearest the name. One request per page for all names. Plain DOM, no jQuery. */
(function () {
  'use strict';
  var el = document.getElementById('gk-people-names-config');
  if (!el) return;
  var cfg;
  try { cfg = JSON.parse(el.textContent); } catch (e) { return; }
  var t = cfg.t || {};
  function fmt(s, v) { Object.keys(v || {}).forEach(function (k) { s = String(s).replace('%{' + k + '}', v[k]); }); return s; }
  // The account behind core's name link (a.user, the class core's link_to_user gives it): the id GK Core Stuff marks
  // on the link (data-principal-id, module principal_marks). A name without that mark gets no chat icon; its address
  // is never read for the id
  function idOf(a) {
    var id = a.getAttribute('data-principal-id');
    return id && /^\d+$/.test(id) ? id : null;
  }
  function names() {
    return Array.prototype.filter.call(document.querySelectorAll('#content a.user[data-principal-id], #sidebar a.user[data-principal-id]'), function (a) {
      return idOf(a) && !a.dataset.gkPeopleChat;
    });
  }
  // the page as a message: the title the server made from what it drew (an issue's heading and subject, else the
  // page's title); without it the browser's title of the page
  function title() { return cfg.title || document.title; }
  function icon(name) {
    if (!name) return null;
    // GK GUI Stuff's icon: GK Icons when it has the name, else core's sprite
    var n = window.GkGui.icon(name, '', 14);
    return n && n.nodeType === 1 ? n : null;
  }
  function decorate(list, links) {
    list.forEach(function (a) {
      var l = links[idOf(a)];
      a.dataset.gkPeopleChat = l ? '1' : '0';
      if (!l) return;
      var label = fmt(t.chat_in, { name: a.textContent.trim(), app: l.app });
      var link = document.createElement('a');
      link.className = 'gk-people-chat-app';
      link.href = l.href; link.target = '_blank'; link.rel = 'noopener noreferrer';
      link.title = label; link.setAttribute('aria-label', label);
      var i = icon(l.icon);
      // an icon link as core's (icon-only): its colour and hover are core's icon links', not grey
      if (i) { link.appendChild(i); link.classList.add('icon-only'); } else link.textContent = l.app;
      // the page's address copied with GK GUI Stuff's copy, its whisper under the icon
      if (l.copy) link.addEventListener('click', function () { window.GkGui.copy(window.location.href, fmt(t.copied, { app: l.app }), link); });
      // the lamp (gui_stuff user_status) is always nearest the name: the icon goes after it. The name is core's link
      // found by its class; the walk passes only gui_stuff's own lamps (.gk-gui-stuff-status) and stops at anything
      // else, so no element of core's is chosen by its place
      var after = a, n = a.nextElementSibling;
      while (n && n.classList.contains('gk-gui-stuff-status')) { after = n; n = n.nextElementSibling; }
      after.insertAdjacentElement('afterend', link);
    });
  }
  function run() {
    var list = names();
    if (!list.length) return;
    // The links for the people the page was drawn with came with the page (gui_stuff's page package); only
    // names the server did not draw are asked for
    var P = window.gkGuiStuffPulse, given = P && P.data('people_name_links');
    if (given) {
      var asked = {};
      (given.asked || []).forEach(function (i) { asked[i] = true; });
      decorate(list.filter(function (a) { return asked[idOf(a)]; }), given.users || {});
      list = list.filter(function (a) { return !asked[idOf(a)]; });
      if (!list.length) return;
    }
    var ids = [];
    list.forEach(function (a) { var i = idOf(a); if (ids.indexOf(i) < 0) ids.push(i); });
    var q = '?ids=' + ids.join(',') + '&title=' + encodeURIComponent(title()) + '&url=' + encodeURIComponent(window.location.href.split('#')[0]);
    fetch(cfg.url + q, { credentials: 'same-origin', headers: { Accept: 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : { users: {} }; })
      .then(function (d) { decorate(list, d.users || {}); })
      .catch(function () {});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
})();
