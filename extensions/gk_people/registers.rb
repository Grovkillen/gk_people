# frozen_string_literal: true

module GkPeople
  # Who may see and change the registers. Global permissions (granted through a role in any project); an
  # administrator always may. Nobody without GK GUI Stuff (GkPeople.gui?, gate.rb): these open pages, and the pages
  # are closed then; they protect nothing.
  module Access
    module_function

    def view?(user = User.current) = GkPeople.gui? && (user.admin? || user.allowed_to?(:gk_people_view, nil, global: true))
    def manage?(user = User.current) = GkPeople.gui? && (user.admin? || user.allowed_to?(:gk_people_manage, nil, global: true))
    def identifiers?(user = User.current) = GkPeople.gui? && (user.admin? || user.allowed_to?(:gk_people_manage_identifiers, nil, global: true))
  end

  PERSON_EVENTS = %w[person_created person_changed person_type_changed person_linked person_unlinked identifier_added identifier_removed
                     subject_access_made person_pin_set person_pin_locked person_consent_given person_consent_revoked].freeze
  # organization_parent_set, the parent set or changed
  ORG_EVENTS = %w[organization_created organization_changed organization_approval_changed organization_relation_added
                  organization_relation_ended organization_parent_set].freeze


  # The detail fields that hold people, per event kind, whatever their form: an account (records' principal or a
  # plain user id), a register person or a group of people (records' reference of people's own kinds), or a list
  # holding them. Declared to records as person_fields; a kind not named here holds no person.
  PERSON_FIELDS = {
    'person_created' => %w[user_id], 'person_linked' => %w[user_id account], 'person_unlinked' => %w[user_id account],
    'subject_access_made' => %w[by], 'account_deleted' => %w[user_id],
    'responsibility_assigned' => %w[deputy scope_group], 'responsibility_deputy_set' => %w[deputy scope_group],
    'responsibility_ended' => %w[scope_group], 'role_removed_by_hand' => %w[by],
    'person_group_member_added' => %w[person member], 'person_group_member_removed' => %w[person member],
    'group_member_added' => %w[member user_id], 'group_member_removed' => %w[member user_id],
    'see_as_started' => %w[as], 'see_as_viewed' => %w[by], 'reserve_created' => %w[account], 'reserve_retired' => %w[owner],
    'shared_roles_changed' => %w[added removed],
    # The other post of a merge or of "Det är olika" (a register person when the events are a person's)
    'quick_merged' => %w[into], 'quick_merged_in' => %w[from], 'quick_marked_different' => %w[other]
  }.freeze

  def self.person_fields(kind) = PERSON_FIELDS.fetch(kind.to_s, [])

  # The detail fields that carry the quick line, declared to records as private_fields, so records shows them only to a
  # reader who may see the event's target (the person or the organization) and to no one while it is voided. The events
  # keep them as written.
  PRIVATE_FIELDS = { 'person_created' => %w[text parts], 'organization_created' => %w[text parts], 'quick_part_moved' => %w[text] }.freeze

  # An event kind of people's in records, with its person fields and private fields when records takes them (an
  # older records without them gets the kind as before)
  def self.register_event!(kind, target: nil)
    opts = { plugin: :gk_people, label_key: "label_gk_people_event_#{kind}", target: target }
    fields = person_fields(kind)
    opts[:person_fields] = fields if fields.any? && ::GkRecords::Kinds.method(:register).parameters.any? { |_, n| n == :person_fields }
    bound = PRIVATE_FIELDS.fetch(kind.to_s, [])
    opts[:private_fields] = bound if bound.any? && ::GkRecords::Kinds.respond_to?(:private_fields?) && ::GkRecords::Kinds.private_fields?
    ::GkRecords::Kinds.register_event(kind, **opts)
  end

  # The registers as records targets, so persons and organizations get notes, events and links like everything
  # else (records calls this from its init.rb: people loads before records)
  def self.register_registers!
    ::GkRecords::Targets.register('person', model: 'GkPeoplePerson',
                                             visible: ->(_p, user) { Access.view?(user) }, editable: ->(_p, user) { Access.manage?(user) },
                                             label: ->(p) { p.name }, url: ->(p) { { controller: 'gk_people_persons', action: 'show', id: p.id } })
    ::GkRecords::Targets.register('organization', model: 'GkPeopleOrganization',
                                                   visible: ->(_o, user) { Access.view?(user) }, editable: ->(_o, user) { Access.manage?(user) },
                                                   label: ->(o) { o.name }, url: ->(o) { { controller: 'gk_people_organizations', action: 'show', id: o.id } })
    ::GkRecords::Targets.register('responsibility', model: 'GkPeopleResponsibility',
                                                     visible: ->(_r, user) { Access.view?(user) }, editable: ->(_r, user) { Responsibilities.manage?(user) },
                                                     label: ->(r) { r.name }, url: ->(r) { { controller: 'gk_people_responsibilities', action: 'show', id: r.id } })
    (PERSON_EVENTS + Responsibilities::EVENTS + RoleSync::EVENTS).each { |k| register_event!(k, target: 'person') }
    %w[responsibility_created responsibility_changed].each { |k| register_event!(k, target: 'responsibility') }
    ORG_EVENTS.each { |k| register_event!(k, target: 'organization') }
    # a credential's events land on its holder, a person or an organization (no single target)
    Credentials::EVENTS.each { |k| register_event!(k) }
    # A quick contact's events land on a person or an organization (no single target)
    Quick::EVENTS.each { |k| register_event!(k) }
    PersonGroups.register_target!
    RefKinds.register!
    # what a review covers and the places' rows are drawn on pages: only with GK GUI Stuff (gate.rb)
    register_review_content! if GkPeople.gui?
  end

  # What a review covers (records' Verification.content, which signoff's signature is bound to): a chosen list of
  # facts per kind, never all the columns (a migration that adds a column must never make a review stand as
  # changed). A column people adds for its own working (the
  # picture folder, the number's digits) is never on the list. A fact added later goes at the end of its list, and
  # every review of that kind then stands as changed once: decide that with the owner.
  REVIEW_FACTS = {
    'organization' => %w[name short_name org_no address city sni country phone email website parent_id active],
    'person' => %w[display_name first_name last_name organization_id title email phone languages active],
    'group' => %w[lastname]
  }.freeze

  # Each kind is also a place of records' verification status, with its row name, words, optional levels and review
  # (VerificationPlaces); records is asked for the function, so the rows show without a tracker being chosen
  def self.register_review_content!
    VerificationPlaces.register!(REVIEW_FACTS)
    VerificationPlaces.request_feature!
  end

  # Register persons and groups of people as references in records' details: records asks people for the name and
  # the page. A viewer who may not see the registers (people's own test, Access.view?; an administrator sees all)
  # gets nil, also for one that is gone, so nothing says whether it is there; one that is gone is:gone.
  # restricted: and list:: how many active users may not see the registers, for records' mark, and the ones a viewer
  # may see for a form in another plugin (triggers). An older records without them gets the kinds as before.
  module RefKinds
    KINDS = { person: ['GkPeoplePerson', 'gk_people_persons'], person_group: ['GkPeopleGroup', 'gk_people_groups'] }.freeze
    LIST_LIMIT = 50
    CACHE_TTL = 600 # seconds, as records' own map of people not everyone may see

    module_function

    def register!
      return unless defined?(::GkRecords::Ref) && ::GkRecords::Ref.respond_to?(:register_kind)

      takes = ::GkRecords::Ref.method(:register_kind).parameters.map(&:last)
      KINDS.each do |kind, (model, controller)|
        opts = { plugin: :gk_people, label: ->(id, viewer) { label(model, id, viewer) }, url: ->(id, viewer) { url(controller, id, viewer) } }
        opts[:restricted] = ->(_id) { hidden_from } if takes.include?(:restricted)
        opts[:list] = ->(viewer, query) { list(model, viewer, query) } if takes.include?(:list)
        ::GkRecords::Ref.register_kind(kind, **opts)
      end
    end

    def may?(viewer) = viewer.is_a?(::User) && Access.view?(viewer)

    def label(model, id, viewer)
      return nil unless may?(viewer)

      model.constantize.find_by(id: id)&.name || :gone
    end

    def url(controller, id, viewer) = may?(viewer) ? { controller: controller, action: 'show', id: id } : nil

    # How many active users may not see the registers (Access.view?), nil when all may. The same for every register
    # person and group, since the registers are seen whole or not at all. Counted as records counts for its mark
    # (active accounts, no administrator, not Anonymous) with each account's own roles (a shared account's matrix
    # left out: Actor.raw). Kept for the request on the current user and across requests under records' key for
    # its map (it changes with people, memberships, roles and projects), at most CACHE_TTL.
    def hidden_from
      v = ::User.current
      n = v.instance_variable_get(:@gk_people_registers_hidden)
      n = v.instance_variable_set(:@gk_people_registers_hidden, cached_count) if n.nil?
      n.positive? ? n : nil
    end

    def cached_count
      vis = defined?(::GkRecords::Visibility) ? ::GkRecords::Visibility : nil
      return count_hidden unless vis.respond_to?(:map_key)

      ::Rails.cache.fetch("gk_people/registers_hidden/#{vis.map_key}", expires_in: CACHE_TTL) { count_hidden }
    end

    def count_hidden
      users = ::User.where(type: 'User', status: ::Principal::STATUS_ACTIVE, admin: false).to_a
      Actor.raw { users.count { |u| !Access.view?(u) } }
    end

    # The persons or groups the viewer may see, by name, at most LIST_LIMIT: [[id, name],...]; nothing for a viewer
    # who may not see the registers. Only active ones: a form picks among those in use, an inactive one is still
    # named where it is already referred to (label).
    def list(model, viewer, query)
      return [] unless may?(viewer)

      klass = model.constantize
      rows = klass.active.sorted
      rows = rows.not_merged if rows.respond_to?(:not_merged)
      q = query.to_s.strip
      unless q.empty?
        node = klass == ::GkPeoplePerson ? Sql.full_name(klass.arel_table) : klass.arel_table[:name]
        rows = rows.where(Sql.like(node, q))
      end
      rows.limit(LIST_LIMIT).map { |r| [r.id, r.name.to_s] }
    end
  end

  # The mark for accounts and groups not everyone may see. In lists people builds in JavaScript the server draws it
  # with records' helper (gk_people_mark, GkPeopleActorController#search) and the script only puts it in.
  module Marks
    module_function

    # A name as text (a card, a list of names) with records' short text when the mark holds; the plain name without
    # records
    def text_name(principal, viewer = nil)
      vis = defined?(::GkRecords::Visibility) ? ::GkRecords::Visibility : nil
      vis.respond_to?(:marked_name) ? vis.marked_name(principal, viewer) : principal.name
    end
  end

  def self.records? = defined?(::GkRecords) && ::GkRecords::Targets.find('person')

  # An event on a person or an organization, with whoever did it; never stops the save it follows
  def self.write_on(target, kind, details, reason: nil)
    return unless records?

    actor = User.current
    # a write by a sync is the source's (origin synced, with the source), whoever's key made the call; a write
    # by an import has origin import, with the import, its source and the date of the facts
    origin = Sync.active? ? 'synced' : (Import.active? ? 'import' : (actor.logged? ? 'human' : 'system'))
    details = details.merge(synced_from: Sync.source) if Sync.active? && details.is_a?(Hash)
    details = details.merge(imported: Import.context) if Import.active? && details.is_a?(Hash)
    # The reading in records the write belongs to, so the reading's page lists what it changed
    rid = Sync.active? ? Sync.reading_id : (Import.active? ? Import.context[:reading_id] : nil)
    details = details.merge(reading_id: rid) if rid && details.is_a?(Hash)

    ::GkRecords::Events.write(target, kind, details: details, reason: reason, user: actor.logged? ? actor : nil, origin: origin)
  rescue StandardError => e
    Rails.logger.warn("[gk_people] event #{kind} not written on #{target.class.name} #{target.id}: #{e.message}")
  end

  # People in event details follow records' convention: an account or a group (any Principal) is records'
  # reference, never a name or a login, and records names it by GkRecords::Visibility when it is shown. Events
  # are written only when records is there; without it these give nil, so building the details never fails.
  module Refs
    module_function

    def records? = defined?(::GkRecords::Ref) ? true : false

    def person(user_or_id) = records? ? ::GkRecords::Ref.person(user_or_id) : nil

    # A register person or a group of people is no Principal: records' reference of people's own kinds, person and
    # person_group, given as the object or its id; never a name. A records without such references gets the id as
    # before (person_id, person_group_id).
    def register_person(who) = thing(:person, who)
    def register_group(who) = thing(:person_group, who)

    def thing(kind, obj_or_id)
      return nil if obj_or_id.nil? || !records? # also while the gate is closed (gate.rb): an event names its people
      return ::GkRecords::Ref.thing(kind, obj_or_id) if ::GkRecords::Ref.respond_to?(:thing)

      { "#{kind}_id" => obj_or_id.respond_to?(:id) ? obj_or_id.id : obj_or_id }
    end
  end

  module PersonEvents
    # Name, e-mail and telephone are personal data in plain text, and records cannot test who may see a register
    # person: person_changed says which of them changed, never the values
    PRIVATE = %w[display_name first_name last_name email phone].freeze

    module_function

    # An identifier in an event: its scheme and its value masked as a token is (GkPeople::Token.mask), never the
    # value in clear text; a token's value is kept masked already and is written as it is
    def identifier(ident)
      { scheme: ident.scheme.key, value: ident.scheme.token? ? ident.value.to_s : GkPeople::Token.mask(ident.value) }
    end

    # The person is the target: her name is not repeated in the details
    # A quick contact's created event carries quick: true, the line as written and its parts as read (Quick.event_input)
    def created(person)
      GkPeople.write_on(person, 'person_created', { kind: person.kind, user_id: person.user_id, how: person.link_how, source: person.source }
                                                     .merge({ info_source: person.info_source, info_source_on: person.info_source_on&.to_s }.compact)
                                                     .merge(Quick.event_input(person)))
    end

    # What changed, before and after; the kind and the account have events of their own (triggers listen on them)
    def updated(person)
      ch = person.saved_changes
      if ch.key?('kind')
        GkPeople.write_on(person, 'person_type_changed', { kind: ch['kind'] })
      end
      if ch.key?('user_id')
        old, new = ch['user_id']
        GkPeople.write_on(person, 'person_unlinked', { user_id: old, account: Refs.person(old) }, reason: person.link_reason) if old
        GkPeople.write_on(person, 'person_linked', { user_id: new, account: Refs.person(new), how: person.link_how }, reason: person.link_reason) if new
      end
      rest = ch.slice(*(GkPeoplePerson::TRACKED - %w[kind]))
      hidden = rest.keys & PRIVATE
      rest = rest.except(*PRIVATE)
      rest['changed_fields'] = hidden if hidden.any?
      GkPeople.write_on(person, 'person_changed', rest) if rest.any?
    end
  end

  module OrgEvents
    module_function

    def created(org)
      GkPeople.write_on(org, 'organization_created', { name: org.name, kinds: org.kind_keys, source: org.source }
                                                        .merge({ info_source: org.info_source, info_source_on: org.info_source_on&.to_s }.compact)
                                                        .merge(Quick.event_input(org)))
      parent_set(org, [nil, org.parent_id]) if org.parent_id
    end

    # The parent set or changed, before and after (id and name; an organization's name is no personal data)
    def parent_set(org, (was, now))
      name = ->(id) { id ? GkPeopleOrganization.where(id: id).pick(:name) : nil }
      GkPeople.write_on(org, 'organization_parent_set', { parent_id: [was, now], parent: [name.call(was), name.call(now)] })
    end


    def updated(org)
      ch = org.saved_changes
      if ch.key?('approval_status')
        GkPeople.write_on(org, 'organization_approval_changed', ch.slice('approval_status', 'approval_valid_to', 'risk_class'))
      end
      parent_set(org, ch['parent_id']) if ch.key?('parent_id')
      rest = ch.slice('name', 'short_name', 'org_no', 'address', 'city', 'sni', 'country', 'phone', 'email', 'website', 'owner_langs', 'active', 'approval_valid_to', 'risk_class', 'info_source', 'info_source_on',
                      'location_n', 'location_e', 'location_crs', 'org_form', 'size_class', 'deregistered_on', 'avatar_folder_on', 'avatar_folder', 'avatar_name_rule',
                      'avatar_hide_allowed', 'name_hide_allowed')
      %w[location_n location_e].each { |f| rest[f] = rest[f].map { |v| v&.to_s('F') } if rest[f] }

      rest['kinds'] = org.kinds_change if org.kinds_change
      rest = rest.except('approval_valid_to', 'risk_class') if ch.key?('approval_status')
      GkPeople.write_on(org, 'organization_changed', rest) if rest.any?
    end
  end

  # A token is compared by digest, everything else without regard to case. Only identifiers in force count.
  module Identify
    module_function

    def lookup(scheme_key, value)
      scheme = GkPeopleScheme.active.find_by(key: scheme_key.to_s)
      return nil if scheme.nil? || value.to_s.strip.empty?

      rows = GkPeopleIdentifier.in_force.where(scheme_id: scheme.id)
      rows = scheme.token? ? rows.where(value_digest: GkPeople::Token.digest(value)) : rows.where('lower(value) = lower(?)', value.to_s.strip)
      persons = rows.includes(:person).map(&:person).select(&:active).uniq
      persons.size == 1 ? persons.first : nil # two persons with the same value in a scheme that allows it: no answer
    end
  end

  # The person behind an account, also while the gate to GK GUI Stuff is closed (gate.rb): elevation, the reserve
  # accounts, what those outside see and the account events ask it
  def self.person_for(user)
    return nil unless user.is_a?(::User) && user.id

    GkPeoplePerson.find_by(user_id: user.id)
  end

  # Ready channel links for a person or an account: [{ scheme:, label:, icon:, href:, preferred: }], the preferred
  # first. context: { title:, url: } of the page, for {title}, {url} and {message}. place limits to schemes shown there.
  def self.channels_for(who, context = {}, place: nil)
    person = who.is_a?(::User) ? person_for(who) : who
    return [] unless person.is_a?(GkPeoplePerson)

    person.identifiers_in_force.filter_map do |i|
      next unless i.scheme.contact? && i.scheme.active && (place.nil? || i.scheme.shown_on?(place))

      href = i.link(context)
      href && { scheme: i.scheme.key, label: i.scheme.name, icon: i.scheme.icon, href: href, preferred: i.preferred, value: i.value }
    end.sort_by { |c| c[:preferred] ? 0 : 1 }
  end
end
