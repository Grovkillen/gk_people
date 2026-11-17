// gk_people, small helpers of people's own forms (linked by the views that have them). Plain DOM, no jQuery.
// * The person's form: one of our own people (kind internal) chooses only among organizations with the relation
//   internal (the options carry data-internal), while there is one.
// * A group's page: Skriv and Skriv om above a section fill in records' note form under the page with the section's
//   kind and the note it corrects (a.gk-people-group-write with data-kind and data-corrects).
// * A filter's Verkställ link (data-gk-people-submit) sends its form; Skriv ut (data-gk-people-print) prints the page.
(function () {
  if (window.GkPeopleForms) return;
  window.GkPeopleForms = true;

  function personKind() {
    var k = document.getElementById('person_kind'), o = document.getElementById('person_organization_id');
    if (!k || !o) return;
    function filter() {
      var own = k.value === 'internal', any = o.querySelector('option[data-internal="1"]');
      o.querySelectorAll('option[data-internal]').forEach(function (x) { x.hidden = !!(own && any && x.dataset.internal !== '1'); });
    }
    k.addEventListener('change', filter);
    filter();
  }

  document.addEventListener('click', function (e) {
    var a = e.target.closest ? e.target.closest('a.gk-people-group-write') : null;
    var form = document.querySelector('#gk-records .gk-records-form');
    if (!a || !form) return;
    // The kind is set only in a list that has it among its choices: a writing box that offers a single kind carries
    // it in a hidden field, and a kind the box does not offer leaves the choice as it is
    var sel = form.querySelector('.gk-records-kind'), kind = a.dataset.kind;
    if (kind && sel && sel.options && Array.prototype.some.call(sel.options, function (o) { return o.value === kind; })) sel.value = kind;
    form.querySelector('.gk-records-corrects').value = a.dataset.corrects || '';
    form.querySelector('.gk-records-body').focus();
  });

  // A filter's Verkställ (a link as core draws it) sends the form round it; Skriv ut prints the page
  document.addEventListener('click', function (e) {
    if (!e.target.closest) return;
    var send = e.target.closest('a[data-gk-people-submit]');
    if (send) {
      var f = send.closest('form');
      e.preventDefault();
      if (f) { if (f.requestSubmit) f.requestSubmit(); else f.submit(); }
      return;
    }
    if (e.target.closest('a[data-gk-people-print]')) {
      e.preventDefault();
      window.print();
    }
  });

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', personKind); else personKind();
})();
