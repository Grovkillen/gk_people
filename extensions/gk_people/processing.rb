# frozen_string_literal: true

module GkPeople
  # record_of_processing: every table in the instance that holds a person or an account, with purpose, legal basis,
  # retention and who sees it. The tables are found in the database itself (columns named as Privacy.column_kind
  # says, and the polymorphic references declared below), so a new plugin's table shows up by itself, and without a
  # purpose until someone gives it one. A purpose comes from a declaration in code (a category with texts in the
  # locales, declared by the plugin that owns the table) and can be written over per table under Administration >
  # Personuppgifter (gk_people_processing, texts translated in gk_fields).
  module Processing
    # A declared category: the texts are locale keys text_gk_people_pp_<category>_{purpose,retention,visible}
    CATEGORIES = {
      'account' => 'contract', 'work' => 'legitimate_interests', 'people' => 'legitimate_interests',
      'records' => 'legitimate_interests', 'elevation' => 'legitimate_interests', 'sync' => 'legitimate_interests',
      'consent' => 'legal_obligation' # Keeping the proof of a consent and its revocation
    }.freeze

    # A reference that names its table in a column: [table, type column, type value, id column, :user/:person]
    Ref = Struct.new(:table, :type_column, :type_value, :id_column, :kind)

    module_function

    def declared = (@declared ||= {})
    def refs = (@refs ||= [])
    # A reference kept as a value, not a column: a custom field of the user format, an assignee in a journal's
    # details. { table => [[kind, ->(connection, id) { sql }]] }
    def value_refs = (@value_refs ||= {})
    # Texts other plugins add to a table's retention (retention's active rules): { key => ->(table) { [texts] } }. The
    # list takes what others add at any time (a plugin may load before GK GUI Stuff), but answers nothing while the
    # gate is closed (rule_texts)
    def retention_sources = (@retention_sources ||= {})

    def rule_texts(table)
      return [] unless GkPeople.gui?

      retention_sources.values.flat_map do |src|
        Array(src.call(table.to_s))
      rescue StandardError => e
        Rails.logger.warn("[gk_people] retention source failed for #{table}: #{e.message}")
        []
      end
    end

    # A table's category, declared by the plugin that owns it (core's tables by people)
    # Nothing is declared without GK GUI Stuff (GkPeople.gui?, gate.rb): another plugin's declaration answers nil
    def declare(table, category:, plugin:)
      return nil unless GkPeople.gui?
      raise ArgumentError, "gk_people: no processing category #{category}" unless CATEGORIES.key?(category.to_s)

      declared[table.to_s] = { category: category.to_s, plugin: plugin.to_s }
    end

    def declare_ref(table, type_column:, type_value:, id_column:, kind:)
      return nil unless GkPeople.gui?

      refs << Ref.new(table.to_s, type_column.to_s, type_value.to_s, id_column.to_s, kind.to_sym) unless refs.any? { |r| r.table == table.to_s && r.type_column == type_column.to_s && r.type_value == type_value.to_s }
    end

    def declare_value_ref(table, kind:, &sql)
      return nil unless GkPeople.gui?

      (value_refs[table.to_s] ||= []) << [kind.to_sym, sql]
    end

    # What people declares: core's tables with accounts in them (6.0 to 7.0), its own and records' (records keeps
    # persons as targets: notes, events, links and assessments on a person)
    def declare_defaults!
      %w[users email_addresses user_preferences tokens groups_users members queries oauth_access_grants oauth_access_tokens
         oauth_applications imports webhooks].each { |t| declare(t, category: 'account', plugin: :core) }
      %w[issues journals time_entries attachments watchers changesets messages news comments wiki_contents
         wiki_content_versions issue_categories reactions custom_values].each { |t| declare(t, category: 'work', plugin: :core) }
      %w[gk_people_persons gk_people_identifiers gk_people_organizations gk_people_processing gk_people_groups gk_people_group_members].each { |t| declare(t, category: 'people', plugin: :gk_people) }
      %w[gk_records_notes gk_records_events gk_records_links gk_records_assessments].each { |t| declare(t, category: 'records', plugin: :gk_records) }
      declare(:gk_people_elevations, category: 'elevation', plugin: :gk_people)
      declare(:gk_people_reserve_accounts, category: 'elevation', plugin: :gk_people)
      declare(:gk_people_see_as_sessions, category: 'elevation', plugin: :gk_people)
      declare(:gk_people_sync_log, category: 'sync', plugin: :gk_people)
      declare(:gk_people_imports, category: 'sync', plugin: :gk_people) # The file's rows only until the import is run or discarded
      %w[gk_people_org_kinds gk_people_organization_kinds].each { |t| declare(t, category: 'people', plugin: :gk_people) }
      declare(:gk_people_actor_records, category: 'work', plugin: :gk_people)
      declare(:gk_people_shared_account_roles, category: 'people', plugin: :gk_people)
      declare(:gk_people_shared_accounts, category: 'people', plugin: :gk_people)
      declare(:gk_people_assignments, category: 'people', plugin: :gk_people)
      declare(:gk_people_responsibilities, category: 'people', plugin: :gk_people)
      declare(:gk_people_credentials, category: 'people', plugin: :gk_people)
      declare(:gk_people_role_grants, category: 'people', plugin: :gk_people)
      declare(:gk_people_role_rules, category: 'people', plugin: :gk_people)
      declare(:gk_people_role_sync_runs, category: 'people', plugin: :gk_people)
      declare(:gk_people_consents, category: 'consent', plugin: :gk_people)
      # The words the quick line reads as a role (no person in it, declared as the kinds are); a quick contact is a row
      # of gk_people_persons or gk_people_organizations like any other, and its verification status (records'
      # gk_records_verifications, declared by records) points at the person as records' other tables do
      declare(:gk_people_quick_words, category: 'people', plugin: :gk_people)
      # The accounts' own pictures, six small JPEGs per account, the given picture never kept
      declare(:gk_people_avatars, category: 'people', plugin: :gk_people)
      # The pictures made from an organization's picture folder, removed when the file is gone
      declare(:gk_people_avatar_files, category: 'people', plugin: :gk_people)
      # The part of a folder picture that is used, its place only
      declare(:gk_people_avatar_regions, category: 'people', plugin: :gk_people)
      # The icon chosen for an account, its name only
      declare(:gk_people_avatar_icons, category: 'people', plugin: :gk_people)
      declare_ref('custom_values', type_column: 'customized_type', type_value: 'Principal', id_column: 'customized_id', kind: :user)
      %w[gk_records_notes gk_records_events gk_records_assessments].each do |t|
        declare_ref(t, type_column: 'target_type', type_value: 'person', id_column: 'target_id', kind: :person)
      end
      declare_ref('gk_records_links', type_column: 'target_type', type_value: 'person', id_column: 'target_id', kind: :person)
      declare_ref('gk_records_verifications', type_column: 'target_type', type_value: 'person', id_column: 'target_id', kind: :person)
      declare_ref('gk_records_links', type_column: 'source_type', type_value: 'person', id_column: 'source_id', kind: :person)
      declare(:journal_details, category: 'work', plugin: :core)
      user_cf = "SELECT id FROM custom_fields WHERE field_format = 'user'"
      declare_value_ref(:custom_values, kind: :user) do |c, id|
        "(#{c.quote_column_name('custom_field_id')} IN (#{user_cf}) AND #{c.quote_column_name('value')} = #{c.quote(id.to_s)})"
      end
      # The user fields' ids as text, read here (prop_key is text; a CAST in the database was PostgreSQL's own)
      declare_value_ref(:journal_details, kind: :user) do |c, id|
        v = c.quote(id.to_s)
        cf_keys = ::CustomField.where(field_format: 'user').pluck(:id).map { |i| c.quote(i.to_s) }
        cf = cf_keys.empty? ? '1 = 0' : "#{c.quote_column_name('prop_key')} IN (#{cf_keys.join(', ')})"
        "((#{c.quote_column_name('property')} = 'attr' AND #{c.quote_column_name('prop_key')} IN ('assigned_to_id', 'author_id')) OR " \
          "(#{c.quote_column_name('property')} = 'cf' AND #{cf})) " \
          "AND (#{c.quote_column_name('value')} = #{v} OR #{c.quote_column_name('old_value')} = #{v})"
      end
    end

    # The tables themselves: { table => { person: [cols], user: [cols], self: :user/:person, refs: [Ref] } }
    SELF = { 'users' => :user, 'gk_people_persons' => :person }.freeze
    SKIP = %w[schema_migrations ar_internal_metadata].freeze

    def tables
      c = ::ActiveRecord::Base.connection
      (c.data_sources - SKIP).sort.each_with_object({}) do |t, h|
        cols = c.columns(t).map(&:name)
        e = { person: [], user: [], self: SELF[t], refs: refs.select { |r| r.table == t && cols.include?(r.type_column) && cols.include?(r.id_column) },
              values: value_refs[t] || [] }
        cols.each { |col| (k = Privacy.column_kind(col)) && e[k] << col }
        h[t] = e if e[:person].any? || e[:user].any? || e[:self] || e[:refs].any? || e[:values].any?
      end
    end

    # The record: one line per table, with its texts (the row written here before the declaration) and what is lacking
    Entry = Struct.new(:table, :owner, :columns, :category, :row, keyword_init: true) do
      def purpose = row&.purpose.presence || (category && I18n.t("text_gk_people_pp_#{category}_purpose"))
      def retention = row&.retention.presence || (category && I18n.t("text_gk_people_pp_#{category}_retention"))
      def visible_to = row&.visible_to.presence || (category && I18n.t("text_gk_people_pp_#{category}_visible"))
      def legal_basis = row&.legal_basis.presence || (category && CATEGORIES[category])
      def written? = row.present?
      def rule_texts = Processing.rule_texts(table)
      def missing? = purpose.blank? || legal_basis.blank?
    end

    def entries(found = tables)
      rows = ::GkPeopleProcessing.all.index_by(&:table_name)
      found.map do |t, e|
        d = declared[t]
        cols = (e[:self] ? ['id'] : []) + e[:person] + e[:user] + e[:refs].map { |r| "#{r.type_column}=#{r.type_value}" } +
               (e[:values].any? ? [I18n.t(:text_gk_people_pp_value_ref)] : [])
        Entry.new(table: t, owner: d ? d[:plugin] : owner_of(t), columns: cols, category: d && d[:category], row: rows[t])
      end
    end

    def entry(table) = entries.detect { |e| e.table == table.to_s }

    # The plugin whose migrations create the table (read once from the plugins' db/migrate); else by its prefix
    def owner_of(table) = creators[table.to_s] || Privacy.owner(table)

    def creators
      @creators ||= ::Redmine::Plugin.all.each_with_object({}) do |plugin, h|
        Dir[File.join(plugin.directory.to_s, 'db', 'migrate', '*.rb')].each do |f|
          File.read(f).scan(/create_table[\s(]+[:'"]?([a-z0-9_]+)/).flatten.each { |t| h[t] ||= plugin.id.to_s }
        end
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_people] the tables' owners not read: #{e.message}")
      {}
    end

    # Tables lacking a purpose, optionally only those some owners keep
    def missing(owners: nil) = entries.select { |e| e.missing? && (owners.nil? || Array(owners).map(&:to_s).include?(e.owner)) }
  end

  # subject_access: everything the instance holds about a person, per table and with the table's purpose, the
  # telling things too (timestamps, journal rows, tokens' existence). Made when asked and never kept; that it was
  # made is an event on the person (who, when, how much), without the content.
  module SubjectAccess
    # mentioned: the group Nämnd i (events in records about something else that name the person in their details)
    Part = Struct.new(:entry, :count, :columns, :rows, :mentioned, keyword_init: true)

    module_function

    # Who may see a person's extract: the person herself (through her account) and an administrator
    def allowed?(person, user = User.current) = user.admin? || (user.logged? && person.user_id.present? && person.user_id == user.id)

    # The rows the person is in, per table. A row is hers when it is about her (her account, her person, her
    # identifiers, her membership: a subject column) and shown whole. A row she is only the doer of in a table about
    # someone else (she created another person's identifier, edited someone's journal) shows that she did it, when,
    # and nothing of the other person's data. A table with no subject column (issues, wiki) is shown whole.
    def extract(person)
      user = person.user
      c = ::ActiveRecord::Base.connection
      found = Processing.tables
      entries = Processing.entries(found)
      parts = entries.filter_map do |entry|
        info = found[entry.table]
        subject, actor = conditions(c, info, person, user)
        next if subject.empty? && actor.empty?

        where = (subject + actor).join(' OR ')
        t = c.quote_table_name(entry.table)
        count = c.select_value("SELECT COUNT(*) FROM #{t} WHERE #{where}").to_i
        next if count.zero?

        cols = c.columns(entry.table).map(&:name)
        whole = subject_columns?(info) ? (subject.empty? ? 'FALSE' : "(#{subject.join(' OR ')})") : 'TRUE'
        order = cols.include?('id') ? " ORDER BY #{c.quote_column_name('id')} DESC" : ''
        rows = c.select_all("SELECT #{t}.*, CASE WHEN #{whole} THEN 1 ELSE 0 END AS gk_people_whole FROM #{t} WHERE #{where}#{order} LIMIT #{Privacy::ROWS_SHOWN}").to_a
        keep = cols.select { |col| %w[id kind origin].include?(col) || Privacy.column_kind(col) || col.match?(/(_on|_at|_type)\z/) }
        Part.new(entry: entry, count: count, columns: cols, rows: rows.map do |r|
          own = r['gk_people_whole'].to_i == 1
          cols.map { |col| own || keep.include?(col) ? Privacy.shown(entry.table, col, r[col]) : :other }
        end)
      end
      mention = mentioned(c, entries.detect { |e| e.table == EVENTS_TABLE }, person, user)
      mention ? parts + [mention] : parts
    end

    # Nämnd i: events in records about something else where the person is only named in the details, as her register
    # person ({"ref":"person","id":N}, or in a list {"refs":"person","ids":[...]}) or as her account
    # ({"principal":id}, or in a list {"principals":[...]}). Events on the person herself are in records' own part
    # already.
    # details is a text column (records' 001 migration) holding the JSON Events.write makes with to_json: compact,
    # keys in the order GkRecords::Ref writes them. So the search is exact patterns on the text: LIKE for one; for a
    # list, LIKE finds the rows that could hold it and a regular expression bounded by the brackets, run here in Ruby
    # and never in the database, decides, so 12 never matches 112 or 120. A name or a text value never
    # matches (its quotes would be escaped), and no row is ever cast (a row that is not JSON cannot break it).
    # Shown: the event's number, what kind of thing it is about, its kind, origin and time, and in which fields she
    # is named; never the rest of the details or which thing it is (they may be about someone else).
    EVENTS_TABLE = 'gk_records_events'

    def mentioned(c, entry, person, user)
      return nil unless entry && c.data_source_exists?(EVENTS_TABLE)

      details = c.quote_column_name('details')
      pid = person.id.to_i
      uid = user&.id&.to_i
      like = ->(pattern) { "#{details} LIKE #{c.quote(pattern)}" }
      exact = [like.call(%(%{"ref":"person","id":#{pid}}%))]
      exact << like.call(%(%{"principal":#{uid}}%)) if uid
      # A list: the rows with the list and the number somewhere, then the list itself in Ruby
      loose = ["(#{like.call(%(%{"refs":"person","ids":[%))} AND #{like.call("%#{pid}%")})"]
      loose << "(#{like.call(%(%{"principals":[%))} AND #{like.call("%#{uid}%")})" if uid
      lists = [/\{"refs":"person","ids":\[([0-9]+,)*#{pid}(,[0-9]+)*\]\}/]
      lists << /\{"principals":\[([0-9]+,)*#{uid}(,[0-9]+)*\]\}/ if uid
      not_hers = "NOT (#{c.quote_column_name('target_type')} = 'person' AND #{c.quote_column_name('target_id')} = #{pid})"
      t = c.quote_table_name(EVENTS_TABLE)
      id_col = c.quote_column_name('id')
      ids = c.select_values("SELECT #{id_col} FROM #{t} WHERE (#{exact.join(' OR ')}) AND #{not_hers}").map(&:to_i)
      ids += c.select_rows("SELECT #{id_col}, #{details} FROM #{t} WHERE (#{loose.join(' OR ')}) AND #{not_hers}")
              .select { |_id, text| lists.any? { |re| re.match?(text.to_s) } }.map { |id, _| id.to_i }
      ids = ids.uniq
      count = ids.size
      return nil if count.zero?

      where = "#{id_col} IN (#{ids.sort.last(Privacy::ROWS_SHOWN).join(', ')})"

      shown = %w[id target_type kind origin created_at]
      rows = c.select_all("SELECT #{shown.map { |col| c.quote_column_name(col) }.join(', ')}, #{details} FROM #{t} WHERE #{where} " \
                          "ORDER BY #{c.quote_column_name('id')} DESC LIMIT #{Privacy::ROWS_SHOWN}").to_a
      Part.new(entry: entry, count: count, mentioned: true, columns: shown + [I18n.t(:label_gk_people_sa_fields)], rows: rows.map do |r|
        shown.map { |col| r[col]&.to_s } + [mentioned_fields(r['details'], pid, uid).join(', ')]
      end)
    end

    # The top level fields of the details that name the person
    def mentioned_fields(text, pid, uid)
      d = JSON.parse(text.to_s)
      d.is_a?(Hash) ? d.select { |_k, v| names?(v, pid, uid) }.keys : []
    rescue JSON::ParserError
      []
    end

    # Does a value name the person: her register person or her account, alone or in a list, anywhere inside
    def names?(v, pid, uid)
      case v
      when Hash
        k = v.keys.map(&:to_s).sort
        return true if uid && k == ['principal'] && v.values.first == uid
        return true if uid && k == ['principals'] && Array(v.values.first).include?(uid)
        return true if k == %w[id ref] && v['ref'] == 'person' && v['id'] == pid
        return true if k == %w[ids refs] && v['refs'] == 'person' && Array(v['ids']).include?(pid)

        v.values.any? { |x| names?(x, pid, uid) }
      when Array then v.any? { |x| names?(x, pid, uid) }
      else false
      end
    end

    # Columns that say whom a row is about: the person, the account itself, the account a row belongs to
    SUBJECT_USER_COLUMNS = %w[user_id principal_id resource_owner_id].freeze
    def subject_columns?(info) = !!(info[:self] || info[:person].include?('person_id') || (info[:user] & SUBJECT_USER_COLUMNS).any? || info[:refs].any?)

    # [subject conditions, doer conditions] for the person and her account
    def conditions(c, info, person, user)
      ids = { person: person.id, user: user&.id }
      subject = []
      actor = []
      subject << "#{c.quote_column_name('id')} = #{c.quote(ids[info[:self]])}" if info[:self] && ids[info[:self]]
      %i[person user].each do |k|
        next unless ids[k]

        info[k].each do |col|
          # in a table that names its subject in a reference (records), the account columns are the doer
          own = col == 'person_id' || (SUBJECT_USER_COLUMNS.include?(col) && info[:refs].empty?)
          (own ? subject : actor) << "#{c.quote_column_name(col)} = #{c.quote(ids[k])}"
        end
      end
      info[:values].each { |k, sql| subject << sql.call(c, ids[k]) if ids[k] }
      info[:refs].each do |r|
        next unless ids[r.kind]

        subject << "(#{c.quote_column_name(r.type_column)} = #{c.quote(r.type_value)} AND #{c.quote_column_name(r.id_column)} = #{c.quote(ids[r.kind])})"
      end
      [subject, actor]
    end

    # That an extract was made, on the person: by whom, for whom, how much; never what was in it
    def log!(person, parts)
      GkPeople.write_on(person, 'subject_access_made',
                         { by: GkPeople::Refs.person(User.current), own: person.user_id == User.current.id, tables: parts.size, rows: parts.sum(&:count) })
    end
  end
end
