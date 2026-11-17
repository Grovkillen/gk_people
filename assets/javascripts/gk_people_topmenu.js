// gk_people, the state of elevation and Se som in the top menu, without a bar over the page.
// * The element the hooks draw at the top of the page (.gk-people-topmenu: the line with its box) is put in the account
//   part of the top menu, shown first there by the style sheet (just before it where that part is a dropdown), so that it stands with the
//   account; core hides the top menu on a phone, where the rows in core's menu say the same. Without script it stays
//   at the top of the page.
// * data-gk-people-ribbon: gui_stuff's ribbon in the corner (word, icon, title, role, priority); with action, its button
//   (core's cancel) sends the element's own form, the same as the button in the box (Stega ner, Sluta se som).
// * data-gk-people-frame: a frame round the page while looking as someone else.
(function () {
  if (window.GkPeopleTopMenu) return;
  window.GkPeopleTopMenu = true;

  function data(el) {
    try { return JSON.parse(el.getAttribute('data-gk-people-ribbon') || 'null'); } catch (e) { return null; }
  }

  function start() {
    var el = document.querySelector('.gk-people-topmenu');
    if (!el) return;
    var acc = document.querySelector('#top-menu #account');
    // Where the account part is itself a dropdown, the line stands just before it: a click inside the dropdown's
    // element does not close the dropdown, which would then cover the line's box
    // Else the line goes into the account part; the style sheet puts it first in the part's row (order), so nothing here
    // depends on what core puts first in it
    if (acc) {
      if (acc.matches('[data-controller~="dropdown"]')) acc.parentNode.insertBefore(el, acc);
      else acc.appendChild(el);
    }
    if (el.hasAttribute('data-gk-people-frame')) document.body.classList.add('gk-people-see-as-framed');
    var o = data(el);
    if (!o) return;
    var form = el.querySelector('form.gk-people-topmenu-act');
    window.GkGui.ribbon.show({ key: o.key, word: o.word, line: o.line || '', icon: o.icon, title: o.title, role: o.role, priority: o.priority || 0,
                               action: o.action && form ? { label: o.action, handler: function () { form.submit(); } } : null });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
