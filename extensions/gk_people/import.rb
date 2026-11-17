# frozen_string_literal: true

require 'csv'
require 'digest'

module GkPeople
  # import: organizations or persons from a CSV file, in two steps. The file is read and kept with the choices
  # (GkPeopleImport), and a preview says per row what would happen: new, changed (with each field before and after),
  # unchanged, skipped or rejected (with the reasons). Run, the preview is made again against the registers as they are
  # then and written row by row.
  # * Matching: an organization on its organization number (digits only), a person on her e-mail (without regard to
  #   case); otherwise the row is new. Never on a name.
  # * mode: fill (the default) sets only empty fields, and adds kinds; overwrite sets every field the file has a
  #   value for, and sets the kinds to the file's; skip leaves a match as it is. An empty cell never empties a field.
  # * What a sync source owns is never changed by an import (a warning on the row).
  # * Where the facts come from (source_label, source_on) goes on every row written (info_source, info_source_on) and
  #   on its event in records (origin import, with the import); the run is logged in gk_people_sync_log (source import).
  # The import reads through records. The run makes a reading (GkRecords::Readings) with the uploaded file's name, size
  # and SHA-256 (never the file), the source and the date of the facts, and the source's manifest when one is given
  # (the file must be listed in it with its sha256, or the file is refused), kept to the keys that describe the source;
  # every field the run sets points to the reading, with the source's id for the post and the SHA-256 of the value set.
  # With records there, info_source is no longer filled from the import's source (the reading shows where a field came
  # from; info_source stays for what is written by hand and for a file's own column). The import keeps the parsed rows
  # until it is run or discarded, never the bytes.
  # SCB's CSV of workplaces (profile scb_workplaces, found by its column cfarNr) is read as it is: benamning, orgNr,
  # sni_kod, besoksadress, besok_postort, cfarNr (the source's id) and sweref_n, sweref_e (SWEREF 99 TM, decimal point
  # whatever the language). A workplace is matched on its cfarNr from an earlier reading of the same source. A workplace
  # with an organization number is a child of the company with that number (found, or made with the number and the name
  # of the first of its workplaces in the file, since the file names no company); one with a masked number (a sole
  # trader) has no parent and no number. Telephone, e-mail, the blocking columns and personal numbers are never read.
  module Import
    THREAD_KEY = :gk_people_import_context
    RESOURCES = %w[organizations persons].freeze
    MODES = %w[fill overwrite skip].freeze
    SEPARATORS = { ';' => ';', ',' => ',', 'tab' => "\t" }.freeze
    MAX_ROWS = 5000
    MAX_BYTES = 5 * 1_048_576
    FIELDS = {
      'organizations' => %w[name org_no sni kinds address city country notes active info_source info_source_on source_id parent location_n
                            location_e],
      'persons' => %w[first_name last_name display_name email phone title organization kind notes active info_source info_source_on source_id]
    }.freeze
    # Column headings recognised without a choice (lower case, without spaces, dots or dashes); the first name in a list
    # that a heading has wins (besoksadress before postadress)
    HEADINGS = {
      'name' => %w[name namn benamning benämning foretag företag organisation organisationsnamn foretagsnamn företagsnamn],
      'org_no' => %w[org_no orgno orgnr organisationsnummer organizationnumber orgnummer],
      'kinds' => %w[kinds kind typ typer type types],
      'address' => %w[address adress besoksadress besöksadress postadress],
      'country' => %w[country land landskod],
      'notes' => %w[notes anteckningar notering noteringar kommentar],
      'active' => %w[active aktiv],
      'first_name' => %w[first_name firstname fornamn förnamn],
      'last_name' => %w[last_name lastname efternamn],
      'display_name' => %w[display_name displayname visningsnamn namn name fulltnamn fullständigtnamn],
      'sni' => %w[sni snikod sni_kod snicode],
      'city' => %w[city ort stad besok_postort postort kommun],
      'info_source' => %w[info_source källa kalla source varifrån varifran],
      'info_source_on' => %w[info_source_on källdatum kalldatum datum date sourcedate source_date],
      'email' => %w[email epost e_post mejl mail],
      'phone' => %w[phone telefon tel mobil],
      'title' => %w[title titel befattning roll role],
      'organization' => %w[organization organisation foretag företag arbetsgivare],
      'kind' => %w[kind persontyp],
      'source_id' => %w[source_id källans_id kallans_id external_id cfarnr],
      'parent' => %w[parent parent_org_no överordnad overordnad moderorganisation],
      'location_n' => %w[location_n sweref_n nordkoordinat north],
      'location_e' => %w[location_e sweref_e ostkoordinat östkoordinat east]
    }.freeze
    # SCB's CSV of workplaces (Scb.ps1, the owner's script): the field and the column, nothing else is read
    SCB_PROFILE = 'scb_workplaces'
    SCB_COLUMNS = { 'name' => 'benamning', 'org_no' => 'orgnr', 'sni' => 'sni_kod', 'address' => 'besoksadress', 'city' => 'besok_postort',
                    'source_id' => 'cfarnr', 'location_n' => 'sweref_n', 'location_e' => 'sweref_e' }.freeze
    # The columns of that file never read, whatever is mapped: telephone, e-mail and the blocks
    SCB_NEVER = %w[telefon epost reklamsparr telefonsparr epostsparr].freeze
    # The name of a field in the pointers (records' gk_records_field_origins) when it is not the column's
    POINTER_FIELD = { 'kinds' => 'kind_keys', 'parent' => 'parent_id' }.freeze

    module_function

    # ------------------------------------------------------------------ the context of a run (events, origin)

    def context = Thread.current[THREAD_KEY]
    def active? = !context.nil?

    def within(import, reading = nil)
      before = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = { import_id: import.id, reading_id: reading&.id, source: import.source_label, source_on: import.source_on&.to_s }.compact
      yield
    ensure
      Thread.current[THREAD_KEY] = before
    end

    # records' readings are there: the run makes one, and fields point to it
    def readings? = defined?(::GkRecords::Readings) && GkPeople.records? && ::GkRecords::Readings.ready? ? true : false

    def reading_label(import)
      entry = readings? ? ::GkRecords::Readings.manifest_entry(import.manifest, import.filename) : nil
      entry&.dig('source').presence || import.manifest&.dig('source').presence || import.source_label
    end

    def parse_manifest(value)
      return ::GkRecords::Readings.parse_manifest(value) if defined?(::GkRecords::Readings)
      return nil if value.blank?
      return value.to_unsafe_h.to_h.deep_stringify_keys if value.respond_to?(:to_unsafe_h)
      return value.deep_stringify_keys if value.is_a?(Hash)

      JSON.parse(value.respond_to?(:read) ? value.read : value.to_s)
    rescue JSON::ParserError
      raise ArgumentError, I18n.t(:error_gk_people_import_manifest)
    end

    # ------------------------------------------------------------------ reading the file

    # The text of the file in UTF-8: a byte order mark goes; what is not UTF-8 is read as Windows-1252 (Excel)
    def decode(bytes, encoding = 'auto')
      s = bytes.to_s.dup.force_encoding('BINARY')
      s = s.byteslice(3..) if s.start_with?("\xEF\xBB\xBF".b)
      enc = encoding.to_s
      enc = s.dup.force_encoding('UTF-8').valid_encoding? ? 'UTF-8' : 'Windows-1252' if enc.empty? || enc == 'auto'
      s.force_encoding(enc).encode('UTF-8', invalid: :replace, undef: :replace)
    end

    def separator_for(text, choice = 'auto')
      return SEPARATORS[choice] if SEPARATORS.key?(choice)

      first = text.each_line.first.to_s
      [';', ',', "\t"].max_by { |c| first.count(c) }
    end

    # [headings, rows]; raises ArgumentError with a message the page can show
    def parse(bytes, separator: 'auto', encoding: 'auto')
      raise ArgumentError, I18n.t(:error_gk_people_import_too_big) if bytes.to_s.bytesize > MAX_BYTES

      text = decode(bytes, encoding)
      sep = separator_for(text, separator)
      table = CSV.parse(text, col_sep: sep, liberal_parsing: true).reject { |r| r.compact.all? { |c| c.to_s.strip.empty? } }
      raise ArgumentError, I18n.t(:error_gk_people_import_empty) if table.size < 2
      raise ArgumentError, I18n.t(:error_gk_people_import_too_many, max: MAX_ROWS) if table.size - 1 > MAX_ROWS

      headings = table.first.map { |h| h.to_s.strip }
      rows = table.drop(1).map { |r| headings.each_index.map { |i| r[i].to_s.strip } }
      [headings, rows, SEPARATORS.key(sep) || sep]
    rescue CSV::MalformedCSVError => e
      raise ArgumentError, I18n.t(:error_gk_people_import_malformed, message: e.message)
    end

    def norm_heading(h) = h.to_s.downcase.gsub(/[\s.\-]/, '')

    # The fields matched to columns by their headings: { field => column index }
    # A field's name in every language the plugin speaks (the template's headings are these, so a template made in
    # Swedish is read in an English page and the other way)
    def field_labels(f)
      I18n.available_locales.filter_map { |loc| I18n.t("label_gk_people_import_field_#{f}", locale: loc, default: '').presence }
    end

    # For each field (in FIELDS' order) the first of its names that a heading not yet taken has
    def auto_mapping(resource, headings)
      normed = headings.map { |h| norm_heading(h) }
      FIELDS.fetch(resource).each_with_object({}) do |f, out|
        names = ((HEADINGS[f] || [f]) + field_labels(f)).map { |n| norm_heading(n) }
        i = names.lazy.filter_map { |n| normed.each_index.find { |j| normed[j] == n && !out.value?(j) } }.first
        out[f] = i if i
      end
    end

    # SCB's CSV of workplaces: its column cfarNr says so
    def scb_file?(headings) = headings.any? { |h| norm_heading(h) == SCB_COLUMNS['source_id'] }

    def scb_mapping(headings)
      normed = headings.map { |h| norm_heading(h) }
      SCB_COLUMNS.each_with_object({}) do |(f, col), out|
        i = normed.index(col)
        out[f] = i if i
      end
    end

    # A new import from a file, with the columns matched by their headings (or mapping: { field => heading or index })
    # and its preview. Returns the import; raises ArgumentError (a message for the page) when the file cannot be read.
    # Manifest (a Hash, JSON text or a.json file) is the source's manifest; it must list the file under files with the
    # file's sha256, and the entry's source and source_time (or its top-level source) stand in for an empty source and
    # date. Only the file's name, size and SHA-256 and the keys of manifest.json that describe the source are kept; the rows
    # parsed are kept until the run (or the discard), never the bytes.
    def start!(resource:, bytes:, source_label:, source_on: nil, mode: 'fill', separator: 'auto', encoding: 'auto',
               filename: nil, mapping: nil, user: ::User.current, manifest: nil)
      raise ArgumentError, I18n.t(:error_gk_people_import_resource) unless RESOURCES.include?(resource.to_s)
      raise ArgumentError, I18n.t(:error_gk_people_import_mode) unless mode.blank? || MODES.include?(mode.to_s)

      data = bytes.to_s.b
      facts = { 'file' => File.basename(filename.to_s.tr('\\', '/')).presence || 'import.csv', 'size' => data.bytesize,
                'sha256' => Digest::SHA256.hexdigest(data) }
      manifest = parse_manifest(manifest)
      entry = nil
      records = defined?(::GkRecords::Readings)
      entry = ::GkRecords::Readings.check_manifest!(manifest, facts['file'], sha256: facts['sha256']) if manifest && records
      given = entry&.dig('source').presence || manifest&.dig('source').presence
      source_label = given if source_label.to_s.strip.empty? && given
      source_on = ::GkRecords::Readings.manifest_time(entry['source_time'])&.to_date if source_on.blank? && entry
      raise ArgumentError, I18n.t(:error_gk_people_import_source) if source_label.to_s.strip.empty?

      headings, rows, sep = parse(bytes, separator: separator, encoding: encoding)
      profile = mapping.blank? && resource.to_s == 'organizations' && scb_file?(headings) ? SCB_PROFILE : nil
      map = if mapping.present? then explicit_mapping(resource, headings, mapping)
            elsif profile then scb_mapping(headings)
            else auto_mapping(resource, headings)
            end
      import = ::GkPeopleImport.new(resource: resource.to_s, user_id: user&.logged? ? user.id : nil, filename: filename.to_s[0, 255].presence,
                                  source_label: source_label, source_on: source_on.presence, mode: mode.presence || 'fill',
                                  created_at: Time.current)
      # without records nothing checks manifest.json, and it is not kept
      import.options = { 'headings' => headings, 'separator' => sep, 'encoding' => encoding.to_s, 'mapping' => map, 'profile' => profile,
                         'manifest' => records ? ::GkRecords::Readings.trim_manifest(manifest) : nil, 'file' => facts }.compact
      import.rows_json = { 'rows' => rows }.to_json
      import.save!
      refresh!(import)
      import
    end

    # A mapping given by the asker: a field to a heading (its text) or a column number; unknown fields are left out
    def explicit_mapping(resource, headings, mapping)
      mapping.to_h.each_with_object({}) do |(f, col), out|
        next unless FIELDS.fetch(resource.to_s).include?(f.to_s)

        i = col.to_s.match?(/\A\d+\z/) ? col.to_i : headings.index { |h| norm_heading(h) == norm_heading(col) }
        out[f.to_s] = i if i && i < headings.size
      end
    end

    # ------------------------------------------------------------------ the template

    # The template is made by the system: the headings are the import's own fields in the reader's language, so a
    # template can never drift from what the import reads; the name is revisions' one rule (the kind
    # people.import_template), the separator and encoding Redmine's CSV of the language
    TEMPLATE_KIND = 'people.import_template'

    def template_csv(resource)
      fields = FIELDS.fetch(resource.to_s)
      ::Redmine::Export::CSV.generate do |csv|
        csv << fields.map { |f| I18n.t("label_gk_people_import_field_#{f}") }
      end
    end

    def template_name(resource)
      # the word for what the file holds, in the language of the name (or of a token that forces one, {resource:en})
      word = ->(lang) { I18n.t("label_gk_people_import_#{resource}", locale: lang) }
      return ::GkRevisions::Names.file_name(TEMPLATE_KIND, { resource: word }) if defined?(::GkRevisions::Names)

      "#{TEMPLATE_KIND.tr('.', '_')}_#{resource}.csv"
    end

    def declare_names!
      return unless defined?(::GkRevisions::Names)

      ::GkRevisions::Names.register(TEMPLATE_KIND, plugin: :gk_people, label_key: :label_gk_people_name_import_template, ext: 'csv',
                                                    tokens: %w[resource])
    end

    # ------------------------------------------------------------------ the preview

    def digits(v) = v.to_s.gsub(/\D/, '')
    def truthy?(v) = %w[1 true ja yes x aktiv active].include?(v.to_s.strip.downcase)

    def values_of(import, row)
      import.mapping.each_with_object({}) do |(f, i), out|
        v = row[i.to_i].to_s.strip
        out[f] = v unless v.empty?
      end
    end

    # Every row, with what it would do: [{ 'line', 'values', 'action', 'target_id', 'changes', 'errors', 'warnings' }]
    def preview(import)
      seen = {}
      label = reading_label(import)
      import.raw_rows.each_with_index.map do |row, i|
        values = values_of(import, row)
        r = { 'line' => i + 2, 'values' => values, 'changes' => {}, 'errors' => [], 'warnings' => [] }
        scb_values!(values, r) if import.profile == SCB_PROFILE
        # a row is one post: by the source's id when the file has one, otherwise by organization number or e-mail
        key = values['source_id'].presence&.then { |s| "id:#{s}" }
        key ||= import.resource == 'organizations' ? digits(values['org_no']).presence : values['email'].to_s.downcase.presence
        r['source_label'] = label if values['source_id'].present?
        if key && seen[key]
          r['action'] = 'rejected'
          r['errors'] << I18n.t(:text_gk_people_import_duplicate, line: seen[key])
          next r
        end
        seen[key] = r['line'] if key
        import.resource == 'organizations' ? plan_organization(import, values, r) : plan_person(import, values, r)
        r.delete('source_label')
        r
      end
    end

    # SCB's file: the organization number only when it is one (ten digits, the third 2 or more, as SCB's own test; a
    # masked number or a personal number is no organization number), and it names the company the workplace belongs to
    # rather than the workplace itself
    def scb_values!(values, r)
      raw = values.delete('org_no').to_s
      no = scb_org_no(raw)
      if no
        values['parent_org_no'] = no
      elsif raw.present?
        r['warnings'] << I18n.t(:text_gk_people_import_masked_org_no)
      end
    end

    def scb_org_no(value)
      v = value.to_s.strip
      return nil if v.empty? || v.match?(/x/i)

      d = v.gsub(/\D/, '')
      d = d[2..] if d.size == 12 && d.start_with?('16')
      return nil unless d.size == 10 && d[2].to_i >= 2

      "#{d[0, 6]}-#{d[6, 4]}"
    end

    # A decimal with a point whatever the language (SWEREF 99 TM in metres); an error on the row otherwise
    def decimal_value(cell, field, r)
      v = cell.to_s.strip
      return nil if v.empty?
      return BigDecimal(v) if v.match?(/\A-?\d+(\.\d+)?\z/)

      r['errors'] << I18n.t(:text_gk_people_import_bad_decimal, field: I18n.t("label_gk_people_import_field_#{field}"), value: v)
      nil
    end

    # The post a reading of the same source gave this source's id (records' pointers), when records is there
    def find_by_source(target, r, values)
      return nil unless readings? && values['source_id'].present? && r['source_label']

      ::GkRecords::Readings.find_by_source_id(target, r['source_label'], values['source_id'])
    end

    def find_organization(values)
      no = digits(values['org_no'])
      return nil if no.empty?

      ::GkPeopleOrganization.by_number(no).order(:id).first
    end

    def find_person(values)
      email = values['email'].to_s.strip.downcase
      email.empty? ? nil : ::GkPeoplePerson.where('lower(email) = ?', email).order(:id).first
    end

    # The organization a person row names: by organization number (digits), otherwise by its name
    def organization_for(value)
      v = value.to_s.strip
      return nil if v.empty?

      no = digits(v)
      org = ::GkPeopleOrganization.by_number(no).order(:id).first if no.size >= 6
      org || ::GkPeopleOrganization.where('lower(name) = lower(?)', v).order(:id).first
    end

    # First the post a reading of the same source gave the row's source id, then (not for SCB's workplaces, whose
    # number is the company's) the organization number
    def plan_organization(import, values, r)
      org = find_by_source('organization', r, values)
      org ||= find_organization(values) unless import.profile == SCB_PROFILE
      r['target_id'] = org&.id
      if org && import.mode == 'skip'
        r['action'] = 'skipped'
        return
      end
      org ||= ::GkPeopleOrganization.new
      apply_organization(import, org, values, r)
    end

    def plan_person(import, values, r)
      person = find_by_source('person', r, values) || find_person(values)
      r['target_id'] = person&.id
      if person && import.mode == 'skip'
        r['action'] = 'skipped'
        return
      end
      person ||= ::GkPeoplePerson.new(kind: 'external')
      apply_person(import, person, values, r)
    end

    # The row's values onto the record (not saved); notes the changes, the warnings and the errors on r
    def set_field(import, rec, field, value, r)
      if rec.persisted? && rec.respond_to?(:owned_by_source?) && rec.owned_by_source?(field)
        r['warnings'] << I18n.t(:text_gk_people_import_source_owns, field: field, source: rec.source) if rec[field].to_s != value.to_s
        return
      end
      old = rec[field]
      return if rec.persisted? && import.mode == 'fill' && !(old.nil? || (old.is_a?(String) && old.strip.empty?))
      return if old.to_s == value.to_s

      rec[field] = value
      r['changes'][field] = [old, rec[field]] unless rec[field].to_s == old.to_s
    end

    def apply_organization(import, org, values, r)
      %w[name org_no sni address city country notes].each { |f| set_field(import, org, f, values[f], r) if values.key?(f) }
      set_field(import, org, 'active', truthy?(values['active']), r) if values.key?('active')
      if values.key?('kinds')
        keys = kind_keys_for(values['kinds'], r)
        if org.persisted? && org.owned_by_source?(:kind_keys)
          r['warnings'] << I18n.t(:text_gk_people_import_source_owns, field: 'kinds', source: org.source)
        else
          now = org.kind_keys
          want = import.mode == 'overwrite' || !org.persisted? ? keys : (now | keys)
          if want.sort != now.sort
            org.kind_keys = want
            r['changes']['kinds'] = [now, want]
          end
        end
      end
      # The place in SWEREF 99 TM (a decimal point whatever the language)
      %w[location_n location_e].each do |f|
        next unless values.key?(f)

        d = decimal_value(values[f], f, r)
        set_field(import, org, f, d, r) unless d.nil?
      end
      plan_parent(import, org, values, r)
      finish(import, org, r)
    end

    # The parent, by a column (an organization number, or #id or a plain id) or, in SCB's file, the company of the
    # workplace's organization number. A company not in the register yet is made by the run (r['parent']: number and
    # name); fill sets a parent only where there is none, overwrite moves it.
    def plan_parent(import, org, values, r)
      no = values['parent_org_no']
      cell = values['parent']
      return if no.nil? && cell.nil?

      parent = if no
                 find_organization('org_no' => no)
               else
                 v = cell.to_s.strip
                 d = digits(v)
                 d.size >= 6 ? find_organization('org_no' => v) : ::GkPeopleOrganization.find_by(id: d.to_i)
               end
      if parent.nil? && no.nil?
        r['errors'] << I18n.t(:text_gk_people_import_no_parent, value: cell)
        return
      end
      return if org.persisted? && import.mode == 'fill' && org.parent_id
      return if parent && (org.parent_id == parent.id || (org.persisted? && parent.id == org.id))

      old = org.parent&.name
      if parent
        org.parent_id = parent.id
        r['changes']['parent'] = [old, parent.name]
      else
        name = values['name'].to_s
        r['parent'] = { 'org_no' => no, 'name' => name }
        r['changes']['parent'] = [old, I18n.t(:text_gk_people_import_parent_new, name: name, org_no: no)]
      end
    end

    # Kinds in a cell: keys or names, separated by ; , or |
    def kind_keys_for(cell, r)
      cell.to_s.split(/[;,|]/).map(&:strip).reject(&:empty?).filter_map do |v|
        k = ::GkPeopleOrgKind.where(key: v.downcase).or(::GkPeopleOrgKind.where('lower(name) = lower(?)', v)).first
        r['errors'] << I18n.t(:error_gk_people_unknown_org_kind, keys: v) unless k
        k&.key
      end
    end

    def apply_person(import, person, values, r)
      %w[first_name last_name display_name email phone title notes].each { |f| set_field(import, person, f, values[f], r) if values.key?(f) }
      set_field(import, person, 'active', truthy?(values['active']), r) if values.key?('active')
      if values.key?('kind')
        k = values['kind'].to_s.downcase
        k = { 'intern' => 'internal', 'extern' => 'external' }.fetch(k, k)
        GkPeople::PERSON_KINDS.include?(k) ? set_field(import, person, 'kind', k, r) : r['errors'] << "kind: #{values['kind']}"
      end
      if values.key?('organization')
        org = organization_for(values['organization'])
        if org
          set_field(import, person, 'organization_id', org.id, r)
        else
          r['errors'] << I18n.t(:text_gk_people_import_no_org, value: values['organization'])
        end
      end
      finish(import, person, r)
    end

    # A date in a cell: 2026-09-01 (or 2026-09, the first of the month), or 1/9/2026 and 1.9.2026 day first; an error
    # on the row otherwise
    def row_date(cell, r)
      v = cell.to_s.strip
      return nil if v.empty?

      d = case v
          when /\A\d{4}-\d{2}-\d{2}\z/ then Date.iso8601(v)
          when /\A(\d{4})-(\d{2})\z/ then Date.new(::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i, 1)
          when %r{\A(\d{1,2})[./](\d{1,2})[./](\d{4})\z} then Date.new(::Regexp.last_match(3).to_i, ::Regexp.last_match(2).to_i, ::Regexp.last_match(1).to_i)
          end
      r['errors'] << I18n.t(:text_gk_people_import_bad_date, value: v) unless d
      d
    rescue ArgumentError, Date::Error
      r['errors'] << I18n.t(:text_gk_people_import_bad_date, value: v)
      nil
    end

    def finish(import, rec, r)
      if r['errors'].any?
        r['action'] = 'rejected'
        return
      end
      # where the facts come from: the row's own source and date when the file has them, otherwise the import's
      on = row_date(r['values']['info_source_on'], r)
      return r['action'] = 'rejected' if r['errors'].any?

      # With records' readings the reading says where the facts came from, and info_source keeps only a file's
      # own column (and what is written by hand); without records as before
      if rec.new_record? || r['changes'].any?
        if readings?
          rec.info_source = r['values']['info_source'] if r['values']['info_source'].present?
          rec.info_source_on = on if on
        else
          rec.info_source = r['values']['info_source'].presence || import.source_label
          rec.info_source_on = on || import.source_on
        end
      end
      unless rec.valid?
        r['action'] = 'rejected'
        r['errors'].concat(rec.errors.full_messages)
        return
      end
      # the values as they will be saved (the model tidies some, a country in capitals)
      r['changes'].each { |f, ch| ch[1] = rec[f] unless %w[kinds parent].include?(f) }
      r['changes'].reject! { |f, (was, now)| !%w[kinds parent].include?(f) && was.to_s == now.to_s }
      r['action'] = rec.new_record? ? 'new' : (r['changes'].any? ? 'update' : 'unchanged')
      r['record'] = rec # not stored: the run uses it, the preview drops it
    end

    def counts(rows)
      %w[new update unchanged skipped rejected].index_with { |a| rows.count { |x| x['action'] == a } }
    end

    # The preview kept on the import (without the records)
    def refresh!(import)
      rows = preview(import)
      import.update!(rows_json: { 'rows' => import.raw_rows, 'preview' => rows.map { |x| x.except('record') } }.to_json,
                     counts_json: counts(rows).to_json)
      rows
    end

    # What a run or a discarded import keeps: per row its line, what it did, the record and the changes; the
    # file's rows and the values of rows not written go
    def kept(rows) = rows.map { |x| x.except('record', 'values') }

    # The parsed rows go too
    def discard!(import)
      return unless import.preview?

      attrs = { state: 'discarded', finished_at: Time.current, rows_json: { 'preview' => kept(import.preview_rows) }.to_json }
      import.update!(attrs)
    end

    # ------------------------------------------------------------------ the run

    # The run makes a reading in records first, writes the rows, points every field it set to the reading (with the
    # row's source id), makes the companies SCB's workplaces belong to, and stores the counts on the reading
    def run!(import, user: ::User.current)
      raise ArgumentError, 'state' unless import.state == 'preview'

      rows = preview(import)
      reading = start_reading!(import, rows, user)
      log = ::GkPeopleSyncLog.create!(source: 'import', resource: import.resource, user_id: user&.logged? ? user.id : nil,
                                    started_at: Time.current, received: rows.size)
      errors = []
      companies = {}
      within(import, reading) do
        rows.each do |r|
          rec = r.delete('record')
          if rec&.persisted? && r['action'] == 'unchanged'
            point!(reading, rec, r, [])
            next
          end
          next unless rec && %w[new update].include?(r['action'])

          ok = ::ActiveRecord::Base.transaction do
            if (pa = r['parent'])
              company = companies[pa['org_no']] ||= company_for!(reading, pa, user)
              rec.parent_id = company.id
            end
            rec.created_by_id ||= user.id if rec.new_record? && rec.respond_to?(:created_by_id) && user&.logged?
            rec.save
          rescue ::ActiveRecord::RecordInvalid => e
            rec.errors.add(:base, e.record.errors.full_messages.join(', '))
            false
          end
          if ok
            r['target_id'] = rec.id
            point!(reading, rec, r, r['changes'].keys)
            next
          end

          r['action'] = 'rejected'
          r['errors'] = rec.errors.full_messages
        end
      end
      rows.each { |r| errors << { line: r['line'], errors: r['errors'] } if r['action'] == 'rejected' }
      c = counts(rows)
      made = companies.values.count { |o| o.instance_variable_get(:@gk_people_made_by_import) }
      c['companies'] = made if made.positive?
      log.update!(finished_at: Time.current, created: c['new'], updated: c['update'], unchanged: c['unchanged'] + c['skipped'],
                  rejected: c['rejected'], errors_json: errors.to_json)
      if reading
        ::GkRecords::Readings.finish!(reading, counts: { 'added' => c['new'], 'changed' => c['update'], 'unchanged' => c['unchanged'] + c['skipped'],
                                                          'rejected' => c['rejected'], 'companies' => made }.reject { |k, v| k == 'companies' && v.zero? },
                                                rows: rows.size)
      end
      attrs = { state: 'done', finished_at: Time.current, sync_log_id: log.id, counts_json: c.to_json, rows_json: { 'preview' => kept(rows) }.to_json }
      import.options = import.options.merge('reading_id' => reading.id) if reading
      import.update!(attrs)
      c
    end

    # The reading for the run, or nil without records
    def start_reading!(import, rows, user)
      return nil unless readings?

      mapping = import.profile == SCB_PROFILE ? 'scb_workplaces@1' : "people_#{import.resource}_csv@1"
      ::GkRecords::Readings.start!(target_type: import.resource == 'organizations' ? 'organization' : 'person', source_label: import.source_label,
                                    route: 'file', format: 'csv', source_time: import.source_on, user: user, mode: 'once',
                                    files: [import.options['file']].compact, manifest: import.manifest, mapping: mapping, rows: rows.size,
                                    origin: 'import')
    end

    # The fields the row set point to the reading, with the row's source id; the source id itself is a field of its
    # own, so that a later reading of the same source finds the post even when nothing changed
    def point!(reading, rec, r, changed)
      return unless reading

      sid = r.dig('values', 'source_id').presence
      fields = changed.map { |f| POINTER_FIELD.fetch(f, f) }
      fields << 'source_id' if sid
      ::GkRecords::Readings.set!(reading, rec, fields, source_id: sid) if fields.any?
    end

    # The company of SCB's workplaces with one organization number: found by the number, or made with it and the name of
    # the first of its workplaces in the file (the file names no company); its name and number point to the reading
    def company_for!(reading, pa, user)
      found = find_organization('org_no' => pa['org_no'])
      return found if found

      org = ::GkPeopleOrganization.new(name: pa['name'].presence || pa['org_no'], org_no: pa['org_no'])
      org.created_by_id = user.id if user&.logged?
      org.save!
      org.instance_variable_set(:@gk_people_made_by_import, true)
      ::GkRecords::Readings.set!(reading, org, %w[name org_no]) if reading
      org
    end
  end
end
