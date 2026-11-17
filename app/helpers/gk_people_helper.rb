# frozen_string_literal: true

module GkPeopleHelper
  # The kinds of an organization by their names: the relations in force the reader may see (one in a project only with
  # the project)
  # Each kind carries its key as a class (gk-people-org-kind-<key>), so that a theme can style a kind of its own
  def gk_people_org_kinds(org) = safe_join(org.visible_kinds.map { |k| content_tag(:span, k.name, class: "gk-people-org-kind gk-people-org-kind-#{k.key}#{' gk-people-inactive' unless k.active}") }, ', ')
  def gk_people_person_kind(kind) = l("label_gk_people_person_kind_#{kind}", default: kind.to_s)
  # The person's kind as shown in lists and on the person's page, with the kind as a class (gk-people-person-kind-internal)
  def gk_people_person_kind_tag(kind) = content_tag('span', gk_people_person_kind(kind), class: "gk-people-person-kind gk-people-person-kind-#{kind}")
  def gk_people_scheme_kind(kind) = l("label_gk_people_scheme_kind_#{kind}", default: kind.to_s)
  def gk_people_scheme_kind_tag(kind) = content_tag('span', gk_people_scheme_kind(kind), class: "gk-people-scheme-kind gk-people-scheme-kind-#{kind}")
  # A responsibility's kind with the kind as a class (gk-people-resp-kind-<kind>)
  def gk_people_resp_kind_tag(kind) = content_tag('span', l("label_gk_people_resp_kind_#{kind}"), class: "gk-people-resp-kind gk-people-resp-kind-#{kind}")
  # An organization's approval as GK GUI Stuff's pill in the role of what it means; the status stays a class
  # (gk-people-approval-<status>), so that a theme can find it
  APPROVAL_ROLES = { 'approved' => :saved, 'conditional' => :warning, 'blocked' => :alarm, 'not_assessed' => :muted }.freeze
  def gk_people_approval(status)
    gk_gui_stuff_pill(l("label_gk_people_approval_#{status}", default: status.to_s), role: APPROVAL_ROLES[status.to_s],
                                                                                    html: { class: "gk-people-approval gk-people-approval-#{status}" })
  end

  # What an import does or did: "3 nya, 1 ändrad, 2 avvisade", the zero ones left out
  def gk_people_import_counts(counts)
    parts = %w[new update unchanged skipped rejected companies held to_review outside_selection missing moved_out sole_traders].filter_map do |a|
      n = counts[a].to_i
      n.positive? ? "#{n} #{l("label_gk_people_import_count_#{a}")}" : nil
    end
    content_tag(:span, parts.join(', '), class: 'gk-people-import-counts')
  end

  def gk_people_org_kind_options(selected) = options_for_select(GkPeopleOrgKind.sorted.map { |k| [k.name, k.key] }, selected)
  def gk_people_person_kind_options(selected) = options_for_select(GkPeople::PERSON_KINDS.map { |k| [gk_people_person_kind(k), k] }, selected)

  def gk_people_person_link(person)
    return '' unless person

    link_to(person.name, gk_people_person_path(person), class: "gk-people-person#{' gk-people-inactive' unless person.active}")
  end

  # The mark after the name of an account or a Redmine group the viewer may see but some other active user may
  # not: never who may not see her. "" without records (or an older one), for nobody, for one the viewer may not
  # see and when records' setting has the mark off.
  def gk_people_mark(principal)
    return '' unless principal.is_a?(::Principal) && respond_to?(:gk_records_restricted_mark)

    gk_records_restricted_mark(principal)
  end

  # A register person's mark is her account's; a person without an account has none
  def gk_people_person_mark(person) = gk_people_mark(person&.user)

  # Accounts and Redmine groups are named only to a viewer who may see them by core's own rule: records' test when
  # records is there (GkRecords::Visibility, the same as its own views), otherwise core's (an administrator and
  # the person herself always, else User.visible, Principal.visible for a group). One the viewer may not see is
  # "en person du inte får se". Core's built-in principals (Anonymous, the deleted user, the built-in groups) are
  # shown as core shows them. The answer is kept for the page.
  def gk_people_records_visibility? = defined?(::GkRecords::Visibility) && ::GkRecords::Visibility.respond_to?(:visible_user?) ? true : false

  def gk_people_visible?(principal)
    return true unless principal.is_a?(::Principal)
    return ::GkRecords::Visibility.visible_user?(principal) if gk_people_records_visibility?

    v = ::User.current
    return true if v.admin? || principal.id == v.id || gk_people_builtin?(principal)

    @gk_people_visible ||= {}
    return @gk_people_visible[principal.id] if @gk_people_visible.key?(principal.id)

    scope = principal.is_a?(::Group) ? ::Principal.visible(v) : ::User.visible(v)
    @gk_people_visible[principal.id] = scope.where(id: principal.id).exists?
  end

  def gk_people_builtin?(principal)
    principal.is_a?(::AnonymousUser) || (defined?(::DeletedUser) && principal.is_a?(::DeletedUser)) ||
      (defined?(::GroupBuiltin) && principal.is_a?(::GroupBuiltin)) ? true : false
  end

  def gk_people_hidden_text = gk_people_records_visibility? ? ::GkRecords::Visibility.hidden_text : l(:text_gk_people_hidden_person)

  # May the viewer see the person register (GkPeople::Access.view?, the test the register kind :person uses in
  # records); asked once per page
  def gk_people_register_visible?
    @gk_people_register_visible = GkPeople::Access.view? if @gk_people_register_visible.nil?
    @gk_people_register_visible
  end

  # The register person of an actor record, the same on the actor_records page and in the line under a journal and
  # under the issue's details: named and linked only for one who may see the person register; anyone else gets
  # records' neutral text without a link and without the mark, also for a removed person. mark: false leaves out the
  # mark for one who may see.
  def gk_people_actor_person(person, mark: true)
    return content_tag('span', gk_people_hidden_text, class: 'gk-people-muted') unless gk_people_register_visible?
    return h(l(:label_gk_people_removed_person)) unless person

    safe_join([link_to(person.name, gk_people_person_path(person)), (mark ? gk_people_person_mark(person) : '')])
  end

  # An account's (or group's) name as text, or the neutral text; "" for nobody
  def gk_people_name(principal)
    return '' if principal.nil?

    gk_people_visible?(principal) ? principal.name.to_s : gk_people_hidden_text
  end

  # The name as text with the mark (none for one the viewer may not see); "" for nobody
  def gk_people_named(principal) = principal ? safe_join([gk_people_name(principal), gk_people_mark(principal)]) : ''

  # An account's login, only to a viewer who may see the account; nil otherwise
  def gk_people_login(user) = user.respond_to?(:login) && gk_people_visible?(user) ? user.login.presence : nil

  # Core's link to an account, with the mark: records' gk_records_user when records' helper is on the page, otherwise
  # core's link after the same test; one the viewer may not see is the neutral text, never linked
  def gk_people_user(user)
    return '' unless user
    return gk_records_user(user, system: false) if respond_to?(:gk_records_user)
    return content_tag('span', gk_people_hidden_text, class: 'gk-people-muted') unless gk_people_visible?(user)

    safe_join([link_to_user(user), gk_people_mark(user)])
  end

  # A text from the locales with a name in it (the slot), the name followed by the mark. The text and the name are
  # escaped; the mark is the only markup.
  def gk_people_t_marked(key, slot, principal, name, **args)
    gap = "\u0000"
    pieces = l(key, **args, slot => gap).split(gap, -1)
    named = safe_join([name.to_s, gk_people_mark(principal)])
    safe_join(pieces.each_with_index.flat_map { |piece, i| i < pieces.size - 1 ? [piece, named] : [piece] })
  end

  def gk_people_org_link(org)
    return '' unless org

    link_to(org.name, gk_people_organization_path(org), class: "gk-people-org#{' gk-people-inactive' unless org.active}")
  end

  # The channels as links with the scheme's icon (icons plugin when it has the name, else core's, else the label);
  # data-gk-link-place names the place, so that a plugin drawing external links may mark them (nothing without one)
  def gk_people_channel_links(channels)
    return '' if channels.blank?

    links = channels.map do |c|
      text = c[:preferred] ? safe_join([c[:label], ' ', content_tag('span', "(#{l(:label_gk_people_preferred)})", class: 'gk-people-muted')]) : c[:label]
      link_to(text, c[:href], class: 'gk-people-channel', title: c[:value], target: (c[:href].start_with?('http') ? '_blank' : nil), rel: 'noopener noreferrer',
              data: { gk_link_place: 'people' })
    end
    content_tag('span', safe_join(links, ' '), class: 'gk-people-channels')
  end

  # Beside a field, the reading that last set it (records' gk_records_origin, a link to the reading), with "sätts av
  # <source>" in front when the source owns the field; only "sätts av" without records or without a reading for the
  # field
  def gk_people_source_note(record, attr, origins: nil)
    owned = record.respond_to?(:owned_by_source?) && record.owned_by_source?(attr)
    origin = gk_people_origin(record, attr, origins: origins)
    return '' if !owned && origin.blank?

    parts = []
    parts << l(:text_gk_people_owned_by_source, source: record.source) if owned
    parts << origin if origin.present?
    content_tag('em', safe_join(parts, ' '), class: 'info')
  end

  # The reading that last set a field, or nothing (records' helper; nothing without records)
  def gk_people_origin(record, attr, origins: nil)
    return '' unless respond_to?(:gk_records_origin) && GkPeople.records? && record&.persisted?

    gk_records_origin(record, attr, origins: origins)
  end

  # The sources the record cites (records' citations, a link Stöds av made on the page Kopplingar), shown beside
  # info_source; nothing without records or when it cites nothing. info_source is not touched.
  def gk_people_cited(record)
    return ''.html_safe unless respond_to?(:gk_records_citations) && GkPeople.records? && record&.persisted?

    gk_records_citations(record)
  end

  # Every pointer on a record, for a page that shows many fields (one query)
  def gk_people_origins(record)
    defined?(GkRecords::Readings) && GkPeople.records? ? GkRecords::Readings.origins(record) : {}
  end

  def gk_people_yes_no(v) = v ? l(:general_text_Yes) : l(:general_text_No)

  # What an actor record is about: the issue (linked while it is there), a deleted issue's number and subject, or the
  # project for time without an issue
  def gk_people_actor_target(record)
    return link_to_issue(record.issue, tracker: false) if record.issue

    d = record.details_hash
    return "##{d['id']} #{d['subject']}".strip if record.action == 'deleted' && d['id']
    return "##{record.issue_id}" if record.issue_id

    record.project ? link_to_project(record.project) : ''
  end

  # A credential's status as a badge: valid, expiring, not yet, expired or revoked (colors in gk_people.css)
  def gk_people_credential_status(credential)
    st = credential.status
    core = {"valid" => "badge-status-closed", "expired" => "badge-private", "revoked" => "badge-private", "expiring" => "badge-private"}.fetch(st.to_s, 'badge-status-locked')
    content_tag('span', l("label_gk_people_cred_#{st}"), class: "badge #{core} gk-people-badge gk-people-cred-#{st}")
  end

  # A credential's kind by its name, with the kind's key as a class (gk-people-credential-kind-<key>)
  def gk_people_credential_kind_tag(credential) = content_tag('span', credential.kind&.name || credential.credential_key, class: "gk-people-credential-kind gk-people-credential-kind-#{credential.credential_key}")

  # The kinds a holder lacks for a responsibility, as an orange mark with their names
  def gk_people_lacking(keys)
    return '' if keys.blank?

    names = GkPeople::Credentials.kind_names(keys).join(', ')
    content_tag('span', l(:label_gk_people_lacking), class: 'badge badge-private gk-people-badge gk-people-lacking', title: l(:text_gk_people_lacking, names: names))
  end

  # The mark of a quick contact (still to complete), nothing for others
  def gk_people_quick_mark(rec)
    return '' unless rec && GkPeople::Quick.quick?(rec)

    content_tag('span', l(:label_gk_people_quick), class: 'badge badge-status-open gk-people-badge gk-people-quick-mark', title: l(:text_gk_people_quick_mark))
  end

  # Klar and Slå ihop med... for a quick contact (whoever may change persons and organizations); the number of
  # suggestions on the merge link when known
  def gk_people_quick_actions(rec, suggestions: nil)
    return '' unless GkPeople::Quick.on? && GkPeople::Quick.quick?(rec) && GkPeople::Access.manage? && GkPeople::Quick.merged_into(rec).nil?

    type = GkPeople::Quick.key_of(rec)
    merge = l(:button_gk_people_quick_merge_with)
    merge = safe_join([merge, ' ', gk_gui_stuff_count(suggestions.to_i)]) if suggestions.to_i.positive?
    safe_join([button_to(l(:button_gk_people_quick_done), gk_people_quick_done_path(type, rec.id), method: :post, form_class: 'gk-people-inline',
                                                                                               title: l(:text_gk_people_quick_done), form: { data: { gk_gui_row_action: true } }),
               link_to(merge, gk_people_quick_merge_path(type, rec.id), class: 'icon icon-copy', data: { gk_gui_row_action: true })], ' ')
  end

  # On the page of one merged into another: where it went (records' link same_as); nothing otherwise
  def gk_people_merged_note(rec)
    into = GkPeople::Quick.merged_into(rec)
    return '' unless into

    path = into.is_a?(GkPeopleOrganization) ? gk_people_organization_path(into) : gk_people_person_path(into)
    content_tag('div', safe_join([l(:text_gk_people_quick_merged_into), ' ', link_to(into.name, path)]), class: 'flash warning')
  end

  # The addresses of the state rows in core's account menu (GkPeople::StateMenu), which core asks by name: the page of
  # this elevation (its time, reason and what was done, also the Se som under it), and Sluta se som back to this page
  def gk_people_menu_elevation_path(_project = nil)
    id = GkPeople::SeeAs.state&.dig(:elevation_id) || GkPeople::Elevation.current&.id
    id ? gk_people_elevation_path(id) : nil
  end

  def gk_people_menu_see_as_stop_path(_project = nil) = gk_people_see_as_stop_path(back_url: request.fullpath)
end
