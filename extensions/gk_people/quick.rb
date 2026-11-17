# frozen_string_literal: true

module GkPeople
  # Snabbkontakter.
  #
  # The model: a quick contact is an ordinary person or organization with the attribute quick (the post is incomplete).
  # The created event carries the line as written and its parts as read (QuickParse); nothing else is stored about the
  # line. Klar clears the attribute (an event). Merging is records' link same_as from the quick one to the one that
  # stays: the quick one stays (P1), its links in force are made again from the one that stays and the old ones voided
  # (records keeps them), and it is left out of lists by the link itself (scope not_merged, no column). "Det är olika
  # personer" is records' link not_same, so the pair is not suggested again. Suggestions are never acted on by
  # themselves, not even the same name in the same organization.
  #
  # Who may: on a meeting whoever may add links on the issue (records' linkable), on an organization's page whoever may
  # change it (Access.manage?); Klar, Slå ihop and Det är olika the same as changing a person or an organization
  # (Access.manage?); moving a part afterwards that, or the one who saved the line.
  module Quick
    EVENTS = %w[quick_raised quick_merged quick_merged_in quick_marked_different quick_part_moved].freeze
    SAME = 'same_as'
    NOT_SAME = 'not_same'
    PARTICIPANT = 'meeting_participant'
    MEETING_ORG = 'meeting_organization'
    MODELS = { 'person' => 'GkPeoplePerson', 'organization' => 'GkPeopleOrganization' }.freeze
    # domains of e-mail anyone can have: they suggest no organization
    COMMON_MAIL = %w[gmail.com hotmail.com hotmail.se outlook.com outlook.se live.se live.com yahoo.com yahoo.se icloud.com me.com
                     telia.com spray.se bredband.net msn.com protonmail.com proton.me].freeze
    SUGGESTIONS = 5

    Context = Struct.new(:ref, :issue, :organization, keyword_init: true)
    # tip: what the line's "?" gave instead where partly verified is not on the place (nil when it is)
    Result = Struct.new(:ok, :line, :person, :organization, :org_made, :parsed, :errors, :tip, keyword_init: true)

    module_function

    def t(key, **opts) = ::I18n.t(key, **opts)

    # A fixed reason the quick line gives is a system text in records: yields the text in the instance's language, and
    # what is written with it inside the block keeps the key, so it is shown in the reader's language as it stood.
    # Without it the text as before.
    def as_system(key, &block)
      return yield(t(key)) unless defined?(::GkRecords::SystemText)

      ::GkRecords::SystemText.as_reason(key, &block)
    end

    # The column is there
    def ready?
      ::GkPeoplePerson.column_names.include?('quick') && ::GkPeopleQuickWord.table_exists?
    rescue StandardError
      false
    end

    # The function people.quick (Administration > Funktioner, on by default). Off: no box on a meeting or an
    # organization, no Att komplettera (tab, page, the personal row), no Klar or Slå ihop; saving, moving, Klar, merging
    # and Det är olika refuse with error_gk_people_quick_off. The quick contacts and their events stay as they are.
    FEATURE = 'people.quick'

    def on? = ready? && GkPeople.feature?(FEATURE)
    def off_error = t(:error_gk_people_quick_off)

    # The box Deltagare on a meeting: on, records there, a meeting, and the user may add links on it
    def meeting_box?(issue, user = ::User.current)
      issue && on? && GkPeople.records? && meeting?(issue) && ::GkRecords::Targets.linkable?(issue, user) ? true : false
    end

    # records with the kinds same_as and not_same: merging and the suggestions' memory need them
    def records?
      GkPeople.records? && defined?(::GkRecordsLink) && ::GkRecords::Kinds.find(:link, SAME) && ::GkRecords::Kinds.find(:link, NOT_SAME) ? true : false
    end

    # Whether lists ask records for the merged ones (the scope not_merged on persons and organizations)
    def merged?(_key) = records?
    def merged_ids(key) = ::GkRecordsLink.active.where(kind: SAME, source_type: key.to_s).select(:source_id)

    def key_of(rec) = rec.is_a?(::GkPeopleOrganization) ? 'organization' : 'person'
    def find(type, id) = (m = MODELS[type.to_s]) ? m.constantize.find_by(id: id.to_i) : nil
    def quick?(rec) = rec.respond_to?(:quick) && rec.quick ? true : false

    # The one a record was merged into (nil when it was not), and the end of the chain (itself when not merged)
    def merged_into(rec)
      return nil unless records? && rec&.id

      key = key_of(rec)
      id = ::GkRecordsLink.active.where(kind: SAME, source_type: key, source_id: rec.id, target_type: key).order(:id).pick(:target_id)
      id ? rec.class.find_by(id: id) : nil
    end

    def survivor(rec)
      seen = [rec.id]
      at = rec
      10.times do
        nxt = merged_into(at)
        break if nxt.nil? || seen.include?(nxt.id)

        seen << nxt.id
        at = nxt
      end
      at
    end

    # The words in every language they have (the name and its translations in gk_fields)
    def roles
      ::GkPeopleQuickWord.ensure_seeded!
      ::GkPeopleQuickWord.texts
    rescue StandardError
      []
    end

    def field_label(field) = t(:"label_gk_people_quick_field_#{field}")

    # ------------------------------------------------------------------ the organization a line names
    # Organizations whose name holds one of the name's words (a first narrowing; the comparison is QuickParse's)
    def org_candidates(name, scope = ::GkPeopleOrganization.all)
      words = QuickParse.org_words(name)
      words = [QuickParse.norm_org(name)] if words.empty?
      words = words.reject(&:empty?).first(5)
      return scope.none if words.empty?

      name = ::GkPeopleOrganization.arel_table[:name]
      scope.where(words.map { |w| Sql.like(name, w) }.reduce { |a, b| a.or(b) })
    end

    # The organization with exactly that name, without case and company form; a merged one gives the one it was merged
    # into. The oldest active one when there are several.
    def org_exact(name)
      n = QuickParse.norm_org(name)
      return nil if n.empty?

      hits = org_candidates(name).order(:id).limit(200).to_a.select { |o| QuickParse.norm_org(o.name) == n }
      hits = hits.map { |o| survivor(o) }.uniq(&:id)
      hits.detect(&:active) || hits.first
    end

    def org_by_number(no)
      d = no.to_s.gsub(/\D/, '')
      return nil if d.size < 6

      ::GkPeopleOrganization.not_merged.by_number(d).order(:id).first
    end

    # The organization an e-mail's domain suggests: exactly one active organization with that domain in its e-mail or
    # web address; none for the domains anyone can have
    def org_by_domain(email)
      d = QuickParse.domain(email)
      return nil if d.nil? || COMMON_MAIL.include?(d)

      like = "%#{::GkPeopleOrganization.sanitize_sql_like(d)}%"
      rows = ::GkPeopleOrganization.not_merged.where(active: true).where('lower(email) LIKE ? OR lower(website) LIKE ?', like, like).limit(10).to_a
      rows = rows.select { |o| QuickParse.domain(o.email) == d || QuickParse.web_domain(o.website) == d }
      rows.size == 1 ? rows.first : nil
    end

    # ------------------------------------------------------------------ where the line is written
    def meeting?(issue) = defined?(::GkProjectTypes::Meeting) && ::GkProjectTypes::Meeting.meeting?(issue) ? true : false

    # "issue:12" (a meeting), "organization:5" or nothing; nil when the user may not save there
    def context(ref, user = ::User.current)
      key, id = ref.to_s.split(':', 2)
      case key
      when 'issue'
        return nil unless GkPeople.records?

        issue = ::Issue.visible(user).find_by(id: id.to_i)
        issue && meeting?(issue) && ::GkRecords::Targets.linkable?(issue, user) ? Context.new(ref: "issue:#{issue.id}", issue: issue) : nil
      when 'organization'
        org = ::GkPeopleOrganization.find_by(id: id.to_i)
        org && Access.manage?(user) ? Context.new(ref: "organization:#{org.id}", organization: org) : nil
      when nil, ''
        Access.manage?(user) ? Context.new(ref: nil) : nil
      end
    end

    def meeting_org_ids(issue)
      ::GkRecordsLink.active.where(kind: MEETING_ORG, source_type: 'issue', source_id: issue.id, target_type: 'organization').pluck(:target_id).uniq
    end

    # ------------------------------------------------------------------ reading and saving
    def read(line) = QuickParse.parse(line, roles: roles, known_org: ->(text) { !org_exact(text).nil? })

    def parts_json(parts) = Array(parts).map { |p| p.merge('label' => field_label(p['field'])) }

    # What the line would give, for the preview while typing: its parts, the organization, and the verification step
    # with the word of the place it lands on (the person, or the organization when the line names no person), with the
    # tip when "?" falls back to unverified there
    def preview(line)
      parsed = read(line)
      v = QuickParse.values(parsed[:parts])
      org = v['organization'] ? org_exact(v['organization']) : nil
      place = QuickParse.personish?(v) ? 'person' : 'organization'
      status, fell = QuickParse.status(parsed, VerificationPlaces.levels(place))
      { parts: parts_json(parsed[:parts]), unverified: status == VerificationPlaces::UNVERIFIED, status: status,
        status_label: status ? VerificationPlaces.word(status, place) : nil, tip: fell ? partly_off_tip(place) : nil,
        organization: v['organization'] ? { name: v['organization'], known: !org.nil? } : nil }
    end

    # The tip when "?" gave unverified because partly verified is not on the place, in the place's words
    def partly_off_tip(place)
      t(:text_gk_people_quick_partly_off, partly: VerificationPlaces.word_or_default(VerificationPlaces::PARTLY, place),
                                          unverified: VerificationPlaces.word_or_default(VerificationPlaces::UNVERIFIED, place))
    end

    # The box's help in the words of the place persons (the place most lines land on)
    def help_text(place = 'person')
      t(:text_gk_people_quick_help, partly: VerificationPlaces.word_or_default(VerificationPlaces::PARTLY, place),
                                    unverified: VerificationPlaces.word_or_default(VerificationPlaces::UNVERIFIED, place))
    end

    # Every line of a text, one post each, in order; [Result]
    def save_text!(text, ctx, user: ::User.current) = QuickParse.lines(text).map { |line| save_line!(line, ctx, user: user) }

    # One line: the organization (found by exact name, number or e-mail domain, or made at once as a quick one), the
    # person when the line names one (a name, an e-mail or a telephone), both quick; the created events with the line;
    # unverified ("osäkert") or partly verified (a part with "?", unverified where partly verified is not on the
    # place, with the tip) in records; on a meeting the links participant and organization from the issue. All or
    # nothing. levels: the levels per place instead of records' (a scenario check passes them directly).
    def save_line!(line, ctx, user: ::User.current, levels: nil)
      return Result.new(ok: false, line: line.to_s, parsed: nil, errors: [off_error]) unless on?

      parsed = read(line)
      if parsed[:parts].none? { |p| p['field'] != 'unsure' }
        return Result.new(ok: false, line: line.to_s, parsed: parsed, errors: [t(:error_gk_people_quick_empty)])
      end

      v = QuickParse.values(parsed[:parts])
      personish = !(v['name'] || v['email'] || v['phone']).nil?
      person = nil
      org = nil
      made = false
      tip = nil
      ::GkPeoplePerson.transaction(requires_new: true) do
        org, made = resolve_org(v, ctx, parsed, user, personish)
        person = new_person!(v, org, made, parsed, ctx, user) if personish
        tip = verify!(parsed, [person, (org if made)].compact, user, levels: levels)
        if ctx&.issue
          link!(ctx.issue, person, PARTICIPANT, user) if person
          link!(ctx.issue, org, MEETING_ORG, user) if org
        end
      end
      Result.new(ok: true, line: line.to_s, person: person, organization: org, org_made: made, parsed: parsed, errors: [], tip: tip)
    rescue ::ActiveRecord::RecordInvalid => e
      Result.new(ok: false, line: line.to_s, parsed: parsed, errors: e.record.errors.full_messages)
    end

    # [organization, made now?]
    def resolve_org(vals, ctx, parsed, user, personish)
      if (name = vals['organization'])
        found = org_exact(name)
        return [found, false] if found

        return [create_org!(name, vals, parsed, ctx, user, personish), true]
      end
      if vals['org_no'] && (o = org_by_number(vals['org_no']))
        return [o, false]
      end
      if vals['email'] && (o = org_by_domain(vals['email']))
        return [o, false]
      end
      return [ctx.organization, false] if ctx&.organization

      if ctx&.issue
        ids = meeting_org_ids(ctx.issue)
        return [::GkPeopleOrganization.find_by(id: ids.first), false] if ids.size == 1
      end
      [nil, false]
    end

    # The created event of an organization made from a line with a person names only the organization's part, so a
    # person's name never stands on the organization; a line with only the organization keeps all of it
    def create_org!(name, vals, parsed, ctx, user, personish)
      o = ::GkPeopleOrganization.new(name: name.to_s[0, QuickParse::LIMITS['org_name']], quick: true, created_by_id: user&.logged? ? user.id : nil)
      o.org_no = vals['org_no'][0, QuickParse::LIMITS['org_no']] if vals['org_no']
      o.notes = vals['description'] if !personish && vals['description']
      own = personish ? parsed[:parts].select { |p| %w[organization org_no].include?(p['field']) } : parsed[:parts]
      o.quick_input = input(personish ? own.map { |p| p['text'] }.join(', ') : parsed[:text], own, parsed[:unverified], ctx)
      o.created_event_written = true
      o.save!
      OrgEvents.created(o)
      o
    end

    def new_person!(vals, org, org_made, parsed, ctx, user)
      first, last = QuickParse.split_name(vals['name'])
      notes = [vals['description'], (vals['org_no'] unless org_made || (org && vals['org_no'] && org_by_number(vals['org_no'])&.id == org.id))].compact
      p = ::GkPeoplePerson.new(first_name: first, last_name: last, email: vals['email']&.slice(0, QuickParse::LIMITS['email']),
                             phone: vals['phone']&.slice(0, QuickParse::LIMITS['phone']), title: vals['role']&.slice(0, QuickParse::LIMITS['title']),
                             notes: notes.join(', ').presence, kind: 'external', organization_id: org&.id, quick: true,
                             created_by_id: user&.logged? ? user.id : nil)
      p.display_name = vals['email'] || vals['phone'] unless first
      p.quick_input = input(parsed[:text], parsed[:parts], parsed[:unverified], ctx)
      p.created_event_written = true
      p.save!
      PersonEvents.created(p)
      p
    end

    def input(text, parts, unverified, ctx) = { 'text' => text, 'parts' => parts, 'unverified' => unverified, 'context' => ctx&.ref }

    # What the created event carries for a quick contact (PersonEvents.created, OrgEvents.created)
    def event_input(rec)
      i = rec.respond_to?(:quick_input) ? rec.quick_input : nil
      i ? { quick: true }.merge(i.transform_keys(&:to_sym)) : {}
    end

    # "osäkert" makes what the line made unverified, a part with "?" partly verified (records' Verification), each
    # post on its own place: where partly verified is not on the place, "?" gives unverified. The tip of the first
    # place it fell back on, or nil.
    def verify!(parsed, recs, user, levels: nil)
      return nil unless defined?(::GkRecords::Verification) && ::GkRecordsVerification.table_exists?

      tip = nil
      steps = recs.map do |r|
        place = key_of(r)
        status, fell = QuickParse.status(parsed, levels ? levels.call(place) : VerificationPlaces.levels(place))
        tip ||= partly_off_tip(place) if fell
        [r, status]
      end
      return nil if steps.none? { |_, s| s }

      as_system(parsed[:unverified] ? :text_gk_people_quick_unsure_reason : :text_gk_people_quick_uncertain_reason) do |reason|
        steps.each { |r, s| ::GkRecords::Verification.set!(r, s, user: user, reason: reason) if s }
      end
      tip
    end

    # A link from the meeting, when the kind is there (project_types) and the link is not there already
    def link!(issue, rec, kind, user)
      return nil unless rec && ::GkRecords::Kinds.find(:link, kind)

      key = key_of(rec)
      return nil if ::GkRecordsLink.active.exists?(kind: kind, source_type: 'issue', source_id: issue.id, target_type: key, target_id: rec.id)

      as_system(:text_gk_people_quick_link_reason) do |why|
        ::GkRecordsLink.create!(source_type: 'issue', source_id: issue.id, target_type: key, target_id: rec.id, kind: kind,
                             reason: why, user_id: user&.logged? ? user.id : nil)
      end
    end

    # ------------------------------------------------------------------ the parts afterwards
    def created_event(rec)
      kind = rec.is_a?(::GkPeopleOrganization) ? 'organization_created' : 'person_created'
      ::GkRecordsEvent.where(target_type: key_of(rec), target_id: rec.id, kind: kind).order(:id).first
    end

    # The parts as read when the post was made, with every move since applied (the original is never changed)
    def parts_of(rec)
      return [] unless GkPeople.records? && rec&.id

      ev = created_event(rec)
      d = ev ? ev.details_hash : {}
      return [] unless d['quick']

      parts = Array(d['parts']).map { |p| p.is_a?(Hash) ? p.dup : nil }.compact
      ::GkRecordsEvent.where(target_type: key_of(rec), target_id: rec.id, kind: 'quick_part_moved').order(:id).each do |m|
        md = m.details_hash
        i = md['part'].to_i
        parts[i]['field'] = Array(md['field']).last if parts[i]
        s = md['swapped']
        parts[s.to_i]['field'] = Array(md['field']).first if s && parts[s.to_i]
      end
      parts
    end

    def original_text(rec)
      ev = GkPeople.records? && rec&.id ? created_event(rec) : nil
      d = ev ? ev.details_hash : {}
      d['quick'] ? d['text'].to_s : nil
    end

    def may_move?(rec, user = ::User.current) = rec.is_a?(::GkPeoplePerson) && (Access.manage?(user) || (user.logged? && rec.created_by_id == user.id))

    # A part moved to another field: the person's fields follow, the move is an event (quick_part_moved: the part, its
    # text, the field before and after, and the part it swapped places with when the field takes only one). The line
    # as written stays in the created event. Returns nil or an error text.
    def move_part!(person, index, to, user: ::User.current)
      return off_error unless on?

      to = to.to_s
      return t(:error_gk_people_quick_field) unless QuickParse::MOVABLE.include?(to)

      parts = parts_of(person)
      part = parts[index.to_i]
      return t(:error_gk_people_quick_part) unless part && part['field'] != 'unsure'

      from = part['field']
      return nil if from == to

      text = part['text'].to_s
      other = QuickParse::ONE_ONLY.include?(to) ? parts.index { |p| p['field'] == to } : nil
      ::GkPeoplePerson.transaction(requires_new: true) do
        take(person, from, text)
        if other
          take(person, to, parts[other]['text'].to_s)
          give(person, from, parts[other]['text'].to_s, user) if QuickParse::MOVABLE.include?(from)
        end
        give(person, to, text, user)
        person.display_name = person.email || person.phone if GkPeople::Name.of(nil, person.first_name, person.last_name).empty? && person.display_name.blank?
        person.save!
        details = { part: index.to_i, text: text, field: [from, to] }
        details[:swapped] = other if other
        GkPeople.write_on(person, 'quick_part_moved', details)
      end
      nil
    rescue ::ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.join(', ')
    end

    def list_of(value) = value.to_s.split(/\s*,\s*/).reject(&:empty?)

    def take(person, field, text)
      case field
      when 'name'
        if GkPeople::Name.of(nil, person.first_name, person.last_name).casecmp?(text) || person.display_name.to_s.casecmp?(text)
          person.first_name = nil
          person.last_name = nil
          person.display_name = nil
        end
      when 'email' then person.email = nil if person.email.to_s.casecmp?(text)
      when 'phone' then person.phone = nil if person.phone.to_s == text
      when 'role' then person.title = (list_of(person.title) - [text]).join(', ').presence
      when 'description', 'org_no' then person.notes = (list_of(person.notes) - [text]).join(', ').presence
      when 'organization'
        person.organization_id = nil if person.organization && QuickParse.norm_org(person.organization.name) == QuickParse.norm_org(text)
      end
    end

    def give(person, field, text, user)
      case field
      when 'name'
        person.first_name, person.last_name = QuickParse.split_name(text)
        person.display_name = nil
      when 'email' then person.email = text.delete(' ')
      when 'phone' then person.phone = text[0, QuickParse::LIMITS['phone']]
      when 'role' then person.title = (list_of(person.title) + [text]).uniq.join(', ')[0, QuickParse::LIMITS['title']]
      when 'description' then person.notes = (list_of(person.notes) + [text]).uniq.join(', ')
      when 'organization'
        org = org_exact(text)
        unless org
          parsed = { text: text, parts: [{ 'i' => 0, 'text' => text, 'field' => 'organization', 'uncertain' => false }], unverified: false }
          org = create_org!(text, {}, parsed, nil, user, false)
        end
        person.organization_id = org.id
        issue = meeting_of(person)
        link!(issue, org, MEETING_ORG, user) if issue
      end
    end

    # The meeting a quick person was saved on (the created event's context), when the person may still be seen there
    def meeting_of(rec)
      ev = GkPeople.records? ? created_event(rec) : nil
      ref = ev ? ev.details_hash['context'].to_s : ''
      ref.start_with?('issue:') ? ::Issue.find_by(id: ref.split(':', 2)[1].to_i) : nil
    end

    # ------------------------------------------------------------------ Klar, Slå ihop, Det är olika
    def raise!(rec, user: ::User.current)
      return off_error unless on?
      return t(:error_gk_people_quick_not_quick) unless quick?(rec)

      ::GkPeoplePerson.transaction(requires_new: true) do
        rec.update!(quick: false)
        GkPeople.write_on(rec, 'quick_raised', {})
      end
      nil
    rescue ::ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.join(', ')
    end

    def ref(rec) = rec.is_a?(::GkPeoplePerson) ? Refs.register_person(rec) : { 'organization_id' => rec.id, 'name' => rec.name }

    def different?(a, b)
      return false unless records?

      ka = key_of(a)
      kb = key_of(b)
      ::GkRecordsLink.active.where(kind: NOT_SAME)
                  .where('(source_type = ? AND source_id = ? AND target_type = ? AND target_id = ?) OR (source_type = ? AND source_id = ? AND target_type = ? AND target_id = ?)',
                         ka, a.id, kb, b.id, kb, b.id, ka, a.id).exists?
    end

    def different_ids(rec)
      key = key_of(rec)
      ::GkRecordsLink.active.where(kind: NOT_SAME).touching(key, rec.id).map { |l| ::GkRecords::Links.other(l, key, rec.id) }
                  .select { |k, _id, _out| k == key }.map { |_k, id, _out| id }
    end

    # The quick one (rec) is merged into other, which stays: records' link same_as from rec to other; every link in
    # force on rec (meetings and the rest, not same_as and not_same) is made again with other in its place and the old
    # one voided (kept, with who and when), or only voided when other has it already; an organization's persons and
    # the organizations under it move to other (their own change events). rec keeps its row, its events and its
    # attribute, and is left out of lists. Events quick_merged on rec and quick_merged_in on other. Nil or an error.
    def merge!(rec, other, user: ::User.current)
      return off_error unless on?
      return t(:error_gk_people_quick_records) unless records?
      return t(:error_gk_people_quick_merge_self) unless other && rec.class == other.class && rec.id != other.id
      return t(:error_gk_people_quick_merged_already) if merged_into(rec) || merged_into(other)
      return t(:error_gk_people_quick_marked_different) if different?(rec, other)

      key = key_of(rec)
      who = user&.logged? ? user : ::User.current
      moved = 0
      kept = 0
      persons = 0
      keyed = ::GkRecordsLink.column_names.include?('text_key')
      ::GkRecordsLink.transaction(requires_new: true) do
        ::GkRecordsLink.create!(source_type: key, source_id: rec.id, target_type: key, target_id: other.id, kind: SAME, user_id: who.logged? ? who.id : nil)
        ::GkRecordsLink.active.touching(key, rec.id).where.not(kind: [SAME, NOT_SAME]).order(:id).each do |l|
          out = l.source_type == key && l.source_id == rec.id
          copy = ::GkRecordsLink.new(source_type: l.source_type, source_id: out ? other.id : l.source_id, target_type: l.target_type,
                                  target_id: out ? l.target_id : other.id, kind: l.kind, reason: l.reason.presence,
                                  user_id: who.logged? ? who.id : nil, origin: l.origin)
          # A reason that was a system text keeps its key and values on the copy; a link without a reason gets the
          # system text Flyttad vid sammanslagning
          copy.assign_attributes(text_key: l.text_key, text_values: l.text_values) if keyed && l.text_key.present?
          saved = copy.reason ? copy.save : as_system(:text_gk_people_quick_merge_reason) { |why| copy.reason = why; copy.save }
          if saved || copy.errors.full_messages.include?(t(:error_gk_records_link_twice))
            l.void!(who)
            moved += 1
          else
            kept += 1
          end
        end
        if rec.is_a?(::GkPeopleOrganization)
          ::GkPeoplePerson.where(organization_id: rec.id).find_each do |p|
            p.update!(organization_id: other.id)
            persons += 1
          end
          ::GkPeopleOrganization.where(parent_id: rec.id).find_each { |c| c.update(parent_id: other.id) }
        end
        GkPeople.write_on(rec, 'quick_merged', { into: ref(other), links_moved: moved, links_kept: kept, persons_moved: persons })
        GkPeople.write_on(other, 'quick_merged_in', { from: ref(rec), links_moved: moved, persons_moved: persons })
      end
      nil
    rescue ::ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.join(', ')
    end

    # Det är olika personer (or organisationer): records' link not_same, so the pair is not suggested again; events
    # quick_marked_different on both
    def mark_different!(rec, other, user: ::User.current)
      return off_error unless on?
      return t(:error_gk_people_quick_records) unless records?
      return t(:error_gk_people_quick_merge_self) unless other && rec.class == other.class && rec.id != other.id
      return nil if different?(rec, other)

      key = key_of(rec)
      ::GkRecordsLink.transaction(requires_new: true) do
        ::GkRecordsLink.create!(source_type: key, source_id: rec.id, target_type: key, target_id: other.id, kind: NOT_SAME,
                             user_id: user&.logged? ? user.id : nil)
        GkPeople.write_on(rec, 'quick_marked_different', { other: ref(other) })
        GkPeople.write_on(other, 'quick_marked_different', { other: ref(rec) })
      end
      nil
    rescue ::ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.join(', ')
    end

    # ------------------------------------------------------------------ suggestions and the list
    # Those the record may be the same as: for a person the same first name (in the same organization when it has
    # one) or the same e-mail; for an organization a similar name (QuickParse.
    # similar_org?), so an organization an import (SCB) made or found shows here too. Never one marked as different,
    # one merged away, or itself.
    def suggestions(rec, limit: SUGGESTIONS)
      return [] unless rec&.id && records?

      cands = if rec.is_a?(::GkPeoplePerson)
                return [] if rec.first_name.blank? && rec.email.blank?

                s = ::GkPeoplePerson.not_merged.where(active: true).where.not(id: rec.id)
                ways = []
                if rec.first_name.present?
                  by_name = s.where('lower(gk_people_persons.first_name) = ?', rec.first_name.downcase)
                  ways << (rec.organization_id ? by_name.where(organization_id: rec.organization_id) : by_name)
                end
                ways << s.where('lower(gk_people_persons.email) = ?', rec.email.downcase) if rec.email.present?
                ways.reduce { |a, b| a.or(b) }.order(:id).limit(50).to_a
              else
                org_candidates(rec.name, ::GkPeopleOrganization.not_merged.where(active: true).where.not(id: rec.id)).order(:id).limit(300).to_a
                  .select { |o| QuickParse.similar_org?(rec.name, o.name) }
              end
      gone = different_ids(rec)
      cands.reject { |c| gone.include?(c.id) }.first(limit)
    end

    # The meetings (or any issue) linked to the record that the reader may see
    def meetings(rec, user = ::User.current)
      return [] unless GkPeople.records?

      ids = ::GkRecordsLink.active.where(kind: [PARTICIPANT, MEETING_ORG], source_type: 'issue', target_type: key_of(rec), target_id: rec.id).pluck(:source_id)
      ids.empty? ? [] : ::Issue.visible(user).where(id: ids).order(:id).to_a
    end

    # What tells the two apart, for the suggestion: [[label, this, the other]]
    def compare(rec, other, user = ::User.current)
      date = ->(r) { [r.created_at ? ::I18n.l(::User.current.time_to_date(r.created_at)) : nil, r.created_by&.name].compact.join(', ') }
      meets = ->(r) { meetings(r, user).map { |i| "##{i.id} #{i.subject}" }.join('; ') }
      rows = if rec.is_a?(::GkPeoplePerson)
               [[t(:field_name), rec.name, other.name], [t(:label_gk_people_organization), rec.organization&.name, other.organization&.name],
                [t(:label_gk_people_title), rec.title, other.title], [t(:field_mail), rec.email, other.email],
                [t(:label_gk_people_phone), rec.phone, other.phone], [t(:field_description), rec.notes, other.notes]]
             else
               [[t(:field_name), rec.name, other.name], [t(:label_gk_people_org_no), rec.org_no, other.org_no],
                [t(:label_gk_people_city), rec.city, other.city], [t(:label_gk_people_persons), rec.persons.size.to_s, other.persons.size.to_s],
                [t(:label_gk_people_info_source), rec.info_source, other.info_source]]
             end
      rows + [[t(:label_gk_people_quick_meetings), meets.call(rec), meets.call(other)], [t(:label_gk_people_quick_created), date.call(rec), date.call(other)]]
    end

    # Att komplettera: the quick persons and organizations not completed and not merged; mine: made by the user;
    # project: linked from an issue in the project (where it was made); organization: in it (persons) or it and those
    # under it (organizations)
    def to_complete(user: ::User.current, mine: false, project: nil, organization: nil)
      persons = ::GkPeoplePerson.quick_open.includes(:organization, :created_by)
      orgs = ::GkPeopleOrganization.quick_open.includes(:created_by)
      if mine
        persons = persons.where(created_by_id: user.id)
        orgs = orgs.where(created_by_id: user.id)
      end
      if project && GkPeople.records?
        from = ::GkRecordsLink.active.where(source_type: 'issue', source_id: ::Issue.where(project_id: project.id).select(:id))
        persons = persons.where(id: from.where(target_type: 'person').select(:target_id))
        orgs = orgs.where(id: from.where(target_type: 'organization').select(:target_id))
      end
      if organization
        persons = persons.where(organization_id: organization.id)
        orgs = orgs.where(id: [organization.id] + organization.descendant_ids)
      end
      [persons.order(:created_at, :id), orgs.order(:created_at, :id)]
    end

    # The count on the person's own row (gui_stuff Personal): the quick persons and organizations she made, still open
    def count_mine(user)
      return 0 unless user&.logged? && on?

      ::GkPeoplePerson.quick_open.where(created_by_id: user.id).count + ::GkPeopleOrganization.quick_open.where(created_by_id: user.id).count
    end
  end

  # The box Deltagare on a meeting: above records' row of links, from people's own hook on the issue page (people
  # loads before records, so its hook comes first); only on an issue of the meeting package's tracker
  # (GkProjectTypes::Meeting.meeting?) and for whoever may add links on it.
  # project_types is not changed.
  class QuickHooks < Redmine::Hook::ViewListener
    include GkPeople::Gate::Listener # silent without GK GUI Stuff (gate.rb)
    def view_issues_show_description_bottom(context = {})
      issue = context[:issue]
      v = context[:hook_caller]
      return '' unless v && Quick.meeting_box?(issue) # And only while people.quick is on

      v.content_tag('hr') + v.render(partial: 'gk_people_quick/box', locals: { context: "issue:#{issue.id}", box_key: 'people.quick_meeting',
                                                                        title: l(:label_gk_people_quick_participants), open: false })
    rescue StandardError => e
      Rails.logger.error("[gk_people] quick contacts box not shown: #{e.class}: #{e.message}")
      ''
    end
  end
end
