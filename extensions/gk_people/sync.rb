# frozen_string_literal: true

module GkPeople
  # sync (plugins/people, step 3): an idempotent upsert of organizations,
  # persons and groups from an external system (Monitor first, through erp), matched on source + external_id and
  # never on a name. One call is one list of posts from one source; each post is checked by itself, so a bad post is
  # rejected with its reasons and the good ones are written. The answer and the log (gk_people_sync_log) count
  # created, updated, unchanged and rejected.
  # * The source owns the fields in SOURCE_OWNS of each register (locked here: shown as "sätts av <source>", left out
  #   of forms and REST); everything else is local and never touched (notes, identifiers, the account, groups of
  #   people made here, links to issues). A person's kind is set when the source creates her and then kept (once).
  # * A post the source has removed comes with "deleted": true: the row is flagged (external_deleted_at) and made
  #   inactive, never removed, since local links may hang on it. A post that comes back is active again.
  # * A person names her organization by its external_id in the same source (organization_external_id); a group names
  #   its members by theirs (member_external_ids), and the source owns the members of its groups.
  # * Every write is an event with origin synced and the source (records), so "what was true on 14 March" holds for
  #   synced data too. Called by the integration account (permission gk_people_sync), never by filling tables.
  # * Every call is a reading in records (route api, format json, mode locked, the source as its source, the account
  #   that called), and every field a post set points to it with the post's external_id as the source's id; the
  #   events carry the reading's id. gk_people_sync_log stays the operating log.
  module Sync
    THREAD_KEY = :gk_people_sync_source
    READING_KEY = :gk_people_sync_reading

    RESOURCES = %w[organizations persons groups].freeze
    MAX_POSTS = 1000
    SOURCE_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/

    # What a post may carry per register: the fields the source owns, what it sets once, and the references
    KEYS = {
      'organizations' => %w[external_id deleted name kind kinds org_no address country active],
      'persons' => %w[external_id deleted display_name first_name last_name organization_external_id email phone title active kind],
      'groups' => %w[external_id deleted name active member_external_ids]
    }.freeze

    module_function

    def source = Thread.current[THREAD_KEY]
    def active? = !source.nil?
    def reading = Thread.current[READING_KEY]
    def reading_id = reading&.id


    def as_source(src)
      before = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = src
      yield
    ensure
      Thread.current[THREAD_KEY] = before
    end

    def allowed?(user = ::User.current) = user.admin? || user.allowed_to?(:gk_people_sync, nil, global: true)

    # One call: { source:, posts: [...] } for one register. Returns the log row (with the counts and errors).
    def run(resource, src, posts, user: ::User.current)
      raise ArgumentError, 'resource' unless RESOURCES.include?(resource)

      log = ::GkPeopleSyncLog.create!(source: src.to_s[0, 40], resource: resource, user_id: user&.logged? ? user.id : nil,
                                    started_at: Time.current, received: posts.size)
      counts = Hash.new(0)
      errors = []
      rd = start_reading(resource, src, posts, user)
      before = Thread.current[READING_KEY]
      Thread.current[READING_KEY] = rd
      begin
        as_source(src) do
          posts.each_with_index do |post, i|
            result, messages = one(resource, src, post)
            counts[result] += 1
            errors << { index: i, external_id: (post.is_a?(Hash) ? post['external_id'] : nil), errors: messages } if result == :rejected
          end
        end
      ensure
        Thread.current[READING_KEY] = before
      end
      log.update_columns(finished_at: Time.current, created: counts[:created], updated: counts[:updated], unchanged: counts[:unchanged],
                         rejected: counts[:rejected], errors_json: (errors.any? ? errors.to_json : nil))
      if rd
        ::GkRecords::Readings.finish!(rd, counts: { 'added' => counts[:created], 'changed' => counts[:updated], 'unchanged' => counts[:unchanged],
                                                     'rejected' => counts[:rejected] }, rows: posts.size)
      end
      log
    end

    # The reading in records for one call, or nil without records (a failure to make it never stops the sync)
    def start_reading(resource, src, posts, user)
      return nil unless Import.readings?

      ::GkRecords::Readings.start!(target_type: { 'organizations' => 'organization', 'persons' => 'person', 'groups' => PersonGroups::TARGET }[resource],
                                    source_label: src.to_s, route: 'api', format: 'json', user: user, mode: 'locked',
                                    account: user&.login.presence, rows: posts.size, origin: 'synced')
    rescue StandardError => e
      Rails.logger.warn("[gk_people] sync #{resource} from #{src}: no reading (#{e.class}: #{e.message})")
      nil
    end


    # Checks the call as a whole; nil when it may run, else [status, message]
    def refuse(resource, src, posts)
      return [404, 'unknown register'] unless RESOURCES.include?(resource)
      return [422, 'source: lower case letters, digits and _, at most 40'] unless src.to_s.match?(SOURCE_FORMAT)
      return [422, "#{resource}: a list of posts"] unless posts.is_a?(Array)
      return [422, "at most #{MAX_POSTS} posts per call"] if posts.size > MAX_POSTS

      nil
    end

    # One post: [:created | :updated | :unchanged | :rejected, messages]
    def one(resource, src, post)
      return [:rejected, ['not an object']] unless post.is_a?(Hash)

      post = post.transform_keys(&:to_s)
      unknown = post.keys - KEYS[resource]
      return [:rejected, ["unknown fields: #{unknown.join(', ')}"]] if unknown.any?

      ext = post['external_id'].to_s.strip
      return [:rejected, ['external_id is missing']] if ext.empty? || ext.length > 100

      result = nil
      messages = []
      ::ActiveRecord::Base.transaction(requires_new: true) do
        result, messages = send("upsert_#{resource.chomp('s')}", src, ext, post)
        raise ::ActiveRecord::Rollback if result == :rejected
      end
      [result, messages]
    rescue StandardError => e
      Rails.logger.warn("[gk_people] sync #{resource} #{ext}: #{e.class}: #{e.message}")
      [:rejected, [e.message.to_s[0, 300]]]
    end

    def truthy?(v) = [true, 'true', '1', 1].include?(v)

    # The fields of a post onto a row (only those it carries)
    def apply(row, post, fields)
      fields.each do |f|
        next unless post.key?(f)
        # a list or an object is not a value: the post is rejected (one rescues) instead of being stored as its Ruby text
        raise ArgumentError, "#{f}: a text, a number, true, false or null" if post[f].is_a?(Hash) || post[f].is_a?(Array)

        row[f] = post[f]
      end
      row.active = truthy?(post['active']) if post.key?('active')
    end

    # Removed in the source: flagged and inactive. Back in the source: the flag goes, and it is active again unless
    # the post says otherwise.
    def flag_deleted(row, post)
      if truthy?(post['deleted'])
        row.external_deleted_at ||= Time.current
        row.active = false
      elsif row.external_deleted_at
        row.external_deleted_at = nil
        row.active = true unless post.key?('active')
      end
    end

    def save(row)
      created = row.new_record?
      changed = created || row.changed? || (row.respond_to?(:kinds_pending?) && row.kinds_pending?)
      return [:rejected, row.errors.full_messages] if changed && !row.save

      row.update_columns(synced_at: Time.current) if row.persisted?
      point(row) if changed
      [created ? :created : (changed ? :updated : :unchanged), []]
    end

    # The fields the source owns that this save set point to the call's reading, with the post's external_id
    def point(row)
      return unless reading

      owned = row.class.const_defined?(:SOURCE_OWNS) ? row.class::SOURCE_OWNS : %w[name]
      fields = row.saved_changes.keys & (owned + %w[external_deleted_at])
      fields << 'kind_keys' if row.respond_to?(:kinds_change) && row.kinds_change
      ::GkRecords::Readings.set!(reading, row, fields, source_id: row.external_id) if fields.any?
    end


    def upsert_organization(src, ext, post)
      org = ::GkPeopleOrganization.find_or_initialize_by(source: src, external_id: ext)
      return [:unchanged, []] if org.new_record? && truthy?(post['deleted'])

      # the kinds are keys in the register: kind (one) or kinds (a list); the source owns them. A new one without
      # kinds is a customer, as before, when the register has that kind.
      if post.key?('kinds') || post.key?('kind')
        keys = Array(post.key?('kinds') ? post['kinds'] : post['kind']).map(&:to_s)
        unknown = keys - ::GkPeopleOrgKind.where(key: keys).pluck(:key)
        return [:rejected, ["kind: #{unknown.join(', ')} is not a kind of organization here"]] if unknown.any?

        org.kind_keys = keys
      elsif org.new_record? && ::GkPeopleOrgKind.exists?(key: 'customer')
        org.kind_keys = ['customer']
      end
      apply(org, post, ::GkPeopleOrganization::SOURCE_OWNS - %w[active kind_keys])
      flag_deleted(org, post)
      save(org)
    end

    def upsert_person(src, ext, post)
      person = ::GkPeoplePerson.find_or_initialize_by(source: src, external_id: ext)
      return [:unchanged, []] if person.new_record? && truthy?(post['deleted'])

      if post.key?('organization_external_id')
        oext = post['organization_external_id'].to_s.strip
        if oext.empty?
          person.organization_id = nil
        else
          org = ::GkPeopleOrganization.find_by(source: src, external_id: oext)
          return [:rejected, ["organization_external_id #{oext}: no such organization from #{src}"]] unless org

          person.organization_id = org.id
        end
      end
      # the kind is set when the source creates her, then kept (once)
      person.kind = (post['kind'].presence_in(GkPeople::PERSON_KINDS) || 'external') if person.new_record?
      return [:rejected, ["kind: one of #{GkPeople::PERSON_KINDS.join(', ')}"]] if post['kind'].present? && !GkPeople::PERSON_KINDS.include?(post['kind'])

      apply(person, post, ::GkPeoplePerson::SOURCE_OWNS - %w[active organization_id])
      flag_deleted(person, post)
      save(person)
    end

    def upsert_group(src, ext, post)
      group = ::GkPeopleGroup.find_or_initialize_by(source: src, external_id: ext)
      return [:unchanged, []] if group.new_record? && truthy?(post['deleted'])

      apply(group, post, %w[name])
      flag_deleted(group, post)
      want = nil
      if post.key?('member_external_ids')
        ids = Array(post['member_external_ids']).map { |x| x.to_s.strip }.reject(&:empty?).uniq
        found = ::GkPeoplePerson.where(source: src, external_id: ids).to_a
        missing = ids - found.map(&:external_id)
        return [:rejected, ["member_external_ids: no such persons from #{src}: #{missing.join(', ')}"]] if missing.any?

        want = ids.map { |x| found.detect { |p| p.external_id == x } }
      end
      result, messages = save(group)
      return [result, messages] if result == :rejected || want.nil?

      have = group.memberships.map(&:person_id)
      gone = have - want.map(&:id)
      added = want.reject { |p| have.include?(p.id) }
      gone.each { |pid| PersonGroups.remove(group, ::GkPeoplePerson.find(pid)) }
      added.each { |p| PersonGroups.add(group, p, by: nil) }
      result = :updated if result == :unchanged && (gone.any? || added.any?)
      [result, messages]
    end
  end
end
