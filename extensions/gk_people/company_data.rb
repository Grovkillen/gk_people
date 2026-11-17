# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'
require 'bigdecimal'

module GkPeople
  # Company data: the JSONL file of Get-Foretagsdata.ps1 (one organization a line, Bolagsverket's facts and SCB's
  # workplaces), read through people's imports with the mapping foretagsdata_jsonl, version 1 (in config/mappings).
  # * The file is read a line at a time and never kept; the reading in records keeps its name, size and SHA-256.
  # * Anything that looks like a personal identity number refuses the whole file before anything is kept, and the
  #   message names lines, never values. A sole trader is read only by its key p_<16 hex>, never by a number, and
  #   Bolagsverket's facts on its line are not read.
  # * The selection: the workplaces in the municipalities chosen; an organization is read when at least one of its
  #   workplaces is. The selection is kept with the reading, and each post's pointer keeps the municipality it was read
  #   under, so a later reading counts what it no longer finds within the same selection only.
  # * A field another reading of this mapping (or SCB's workplaces) set and nobody changed since is updated; any other
  #   field that differs is held and shown. An organization is never deactivated, and a workplace never moved to another
  #   company: such a difference is shown to review.
  # * Only an administrator reads company data, on the page (up to the page's limits) or with the rake tasks
  #   gk_people:foretagsdata:preview and :import (up to the file's limits).
  module CompanyData
    PROFILE = 'foretagsdata_jsonl'
    MAPPING = 'foretagsdata_jsonl@1'
    DEFAULT_SOURCE = 'SCB och Bolagsverket'
    BV = 'Bolagsverket'
    SCB = 'SCB'
    # A Swedish personal identity number or co-ordination number in a text: six digits of a date (with the century or
    # not), a separator or none, four digits; checked further by date and Luhn
    PNR = /(?<!\d)(?:19|20)?(\d{2})(\d{2})(\d{2})[-+]?(\d{4})(?!\d)/
    # How many lines a message names
    NAMED = 20

    module_function

    def mapping
      @mapping ||= YAML.safe_load(File.read(File.expand_path("../../config/mappings/#{MAPPING}.yml", __dir__), encoding: 'UTF-8'))
    end

    def limits = mapping['limits']
    def sole_key = Regexp.new(mapping.dig('key', 'sole_trader_key'))

    # Only an administrator reads company data
    def allowed?(user = ::User.current) = user.is_a?(::User) && user.admin?

    # A file of this format: its name ends in .jsonl, or its first character opens a JSON object
    def file?(filename, head = nil) = File.extname(filename.to_s).casecmp?('.jsonl') || head.to_s.lstrip.start_with?('{')

    # The command for a file the page does not take
    def rake_command(name = 'foretagsdata_<datum>.jsonl')
      "bin/rails gk_people:foretagsdata:preview FILE=<sökväg>\\#{File.basename(name.to_s)} KOMMUN=<koder> LOGIN=<administratör> RAILS_ENV=production"
    end

    # A path in a folder that is synced (Dropbox, OneDrive): a real file must never lie there
    def synced_path?(path)
      p = File.expand_path(path.to_s).tr('\\', '/').downcase
      roots = [ENV.fetch('OneDrive', nil), ENV.fetch('OneDriveConsumer', nil), ENV.fetch('OneDriveCommercial', nil)].compact
      roots.any? { |r| p.start_with?(File.expand_path(r).tr('\\', '/').downcase) } || p.split('/').any? { |s| s.match?(/\A(dropbox|onedrive)\b/) }
    end

    # ------------------------------------------------------------------ personal numbers

    def luhn?(ten)
      sum = ten.chars.each_with_index.sum do |c, i|
        v = c.to_i * (i.even? ? 2 : 1)
        v > 9 ? v - 9 : v
      end
      (sum % 10).zero?
    end

    # True for a text holding something that is a personal identity or co-ordination number (a real date, the
    # check digit right)
    def personal_number?(text)
      text.to_s.scan(PNR).any? do |yy, mm, dd, last|
        day = dd.to_i
        day -= 60 if day > 60
        mm.to_i.between?(1, 12) && day.between?(1, 31) && luhn?("#{yy}#{mm}#{dd}#{last}")
      end
    end

    # What is wrong with a line's key: :personal (a personal number, a masked one or one cut short of its century),
    # :sole_key (a sole trader without its key), :malformed (the row is rejected), or nil
    def key_problem(obj)
      raw = obj[mapping.dig('key', 'organization')].to_s.strip
      return raw.match?(sole_key) ? nil : :sole_key if obj[mapping.dig('key', 'sole_trader_flag')] == true
      return :personal if raw.match?(/x/i)
      return :malformed if raw.start_with?('p_')

      d = raw.gsub(/\D/, '')
      return :personal if d.size == 12 && !d.start_with?('16')

      d = d[2..] if d.size == 12
      return :personal if d.size == 10 && d[2].to_i < 2
      return :malformed unless d.size == 10

      nil
    end

    def legal_digits(raw)
      d = raw.to_s.gsub(/\D/, '')
      d.size == 12 ? d[2..] : d
    end

    def format_org_no(digits) = "#{digits[0, 6]}-#{digits[6, 4]}"

    # ------------------------------------------------------------------ reading the file

    # The lines of a file as JSON objects: [line number, object or nil when the line is not JSON]. A line holding a
    # list (or the wrapper an old PowerShell writes, { "value": [...], "Count": n }) gives its elements.
    def each_object(path)
      return enum_for(:each_object, path) unless block_given?

      n = 0
      File.foreach(path, mode: 'r:bom|utf-8') do |raw|
        n += 1
        line = raw.chomp.delete_suffix("\r").strip
        next if line.empty?

        obj = begin
          JSON.parse(line)
        rescue JSON::ParserError
          yield n, nil
          next
        end
        obj = obj['value'] if obj.is_a?(Hash) && obj.key?('value') && obj.key?('Count') && obj['value'].is_a?(Array)
        Array.wrap(obj).each { |o| yield n, (o.is_a?(Hash) ? o : nil) }
      end
    end

    # Reads the file: { rows:, municipalities:, lines: }. Refuses the whole file (ArgumentError naming lines, never
    # values) when it is too large, has too many lines, has a line that is not JSON, has anything like a personal
    # number or a sole trader without its key. Nothing is kept by this.
    def scan(path, max_bytes: limits['max_bytes'], max_rows: limits['max_rows'], page: false)
      size = File.size(path)
      if size > max_bytes
        raise ArgumentError, I18n.t(page ? :error_gk_people_company_page_limit : :error_gk_people_company_too_big,
                                    max: human_size(max_bytes), command: rake_command(path))
      end

      rows = []
      bad = { personal: [], sole_key: [], not_json: [] }
      lines = 0
      each_object(path) do |n, obj|
        lines += 1
        if lines > max_rows
          raise ArgumentError, I18n.t(page ? :error_gk_people_company_page_limit : :error_gk_people_company_too_many,
                                      max: max_rows, command: rake_command(path))
        end
        next bad[:not_json] << n if obj.nil?

        problem = key_problem(obj)
        next bad[problem] << n if %i[personal sole_key].include?(problem)

        group = flatten(obj, n, problem)
        bad[:personal] << n if group.any? { |r| r['values'].any? { |_, v| v.is_a?(String) && personal_number?(v) } }
        rows.concat(group)
      end
      refuse!(bad)
      raise ArgumentError, I18n.t(:error_gk_people_import_empty) if rows.empty?

      { rows: rows, municipalities: municipalities(rows), lines: lines }
    end

    def refuse!(bad)
      { personal: :error_gk_people_company_personal_number, sole_key: :error_gk_people_company_sole_trader_key,
        not_json: :error_gk_people_company_not_json }.each do |kind, key|
        next if bad[kind].empty?

        list = bad[kind].uniq
        more = list.size > NAMED ? I18n.t(:text_gk_people_company_more_lines, count: list.size - NAMED) : ''
        raise ArgumentError, I18n.t(key, lines: "#{list.first(NAMED).join(', ')}#{more}")
      end
    end

    def human_size(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes)

    # ------------------------------------------------------------------ one line to rows

    # One line: the organization's row and a row per workplace, with only the mapping's fields, each with its source
    # and the source's time. A malformed key gives a rejected organization row.
    def flatten(obj, line, problem = nil)
      sole = obj[mapping.dig('key', 'sole_trader_flag')] == true
      raw = obj[mapping.dig('key', 'organization')].to_s.strip
      key = sole ? raw : legal_digits(raw)
      places = Array.wrap(obj['workplaces']).grep(Hash)
      attrs = !sole && obj['attributes'].is_a?(Hash) ? obj['attributes'] : {}
      bv = obj.dig('sources', BV)
      bv_time = bv.is_a?(Hash) ? bv['retrieved'] : nil
      scb_files = obj.dig('sources', SCB).is_a?(Hash) ? Array.wrap(obj.dig('sources', SCB, 'files')).grep(Hash) : []
      first = places.first || {}
      org = { 'line' => line, 'kind' => 'organization', 'key' => key, 'sole_trader' => sole, 'values' => {}, 'origin' => {} }
      if problem == :malformed
        org['malformed'] = true
        return [org]
      end

      mapping['organization'].each do |field, spec|
        v, src, time = organization_value(spec, attrs, first, bv_time, scb_files)
        next if v.nil? || v == ''

        org['values'][field] = v
        org['origin'][field] = [src, time]
      end
      if sole
        org['values']['org_form'] = mapping.dig('sole_traders', 'org_form')
        org['origin']['org_form'] = [SCB, scb_time(first, scb_files)]
      else
        org['values']['org_no'] = format_org_no(key)
        org['origin']['org_no'] = [BV, bv_time]
      end
      org['active'] = !(attrs.dig('active', 'value') == false || attrs.dig('deregistration_date', 'value').present?)
      [org] + places.map { |w| workplace_row(w, line, key, scb_files) }
    end

    # A value of the organization: from Bolagsverket's fact, or (none there) from the first workplace; [value, source, time]
    def organization_value(spec, attrs, first, bv_time, scb_files)
      path = spec['from'].to_s.delete_prefix('attributes.')
      fact = attrs[path]
      if fact.is_a?(Hash) && !fact['value'].nil?
        v = shape(fact['value'], spec)
        return [v, fact['source'].presence || BV, bv_time] unless v.nil? || v == ''
      end
      fb = spec['fallback'].to_s.delete_prefix('workplace.')
      return [nil, nil, nil] if fb.empty? || first.empty?

      [shape(first[fb], spec.merge('join' => spec['join'] && 'postal')), SCB, scb_time(first, scb_files)]
    end

    def workplace_row(w, line, parent_key, scb_files)
      cfar = w[mapping.dig('key', 'workplace')].to_s.strip
      code = w.dig('municipality', 'code').to_s
      time = scb_time(w, scb_files)
      r = { 'line' => line, 'kind' => 'workplace', 'key' => "cfar:#{cfar}", 'source_id' => cfar.presence, 'parent_key' => parent_key,
            'selection' => code, 'selection_label' => w.dig('municipality', 'name').to_s, 'values' => {}, 'origin' => {} }
      r['malformed'] = true if cfar.empty?
      mapping['workplace'].each do |field, spec|
        v = shape(w[spec['from']], spec)
        next if v.nil? || v == ''

        r['values'][field] = v
        r['origin'][field] = [SCB, time]
      end
      c = w['coordinates']
      if c.is_a?(Hash) && c['reference_system'].to_s.include?('3006') && decimal(c['n']) && decimal(c['e'])
        r['values'].merge!('location_n' => decimal(c['n']).to_s('F'), 'location_e' => decimal(c['e']).to_s('F'), 'location_crs' => 'EPSG:3006')
        %w[location_n location_e location_crs].each { |f| r['origin'][f] = [SCB, time] }
      end
      r
    end

    def decimal(v)
      s = v.to_s.strip
      s.match?(/\A-?\d+(\.\d+)?\z/) ? BigDecimal(s) : nil
    end

    # The time of the SCB file a workplace came from: the one whose name holds its municipality's code, else the newest
    def scb_time(w, files)
      code = w.is_a?(Hash) ? w.dig('municipality', 'code').to_s : ''
      f = files.detect { |x| code.present? && x['file'].to_s.include?(code) } || files.max_by { |x| x['retrieved'].to_s }
      f && f['retrieved']
    end

    # A value as the mapping says: a part of it (take), parts joined (join), looked up (map), a date (type)
    def shape(v, spec)
      v = case spec['take']
          when 'first_code' then first_code(v)
          when nil then v
          else v.is_a?(Hash) ? v[spec['take']] : nil
          end
      v = join(v, spec['join']) if spec['join']
      v = mapping.fetch(spec['map'], {})[v.to_s] if spec['map'] && !v.nil?
      v = (Date.iso8601(v.to_s[0, 10]).iso8601 rescue nil) if spec['type'] == 'date' && !v.nil?
      v = v.strip if v.is_a?(String)
      v.is_a?(Hash) || v.is_a?(Array) ? nil : v
    end

    # The code of the first industry (the lowest rank when the list has ranks)
    def first_code(list)
      items = Array.wrap(list).grep(Hash)
      items = items.sort_by { |x| x['rank'].nil? ? 999 : x['rank'].to_i }
      items.first&.dig('code')
    end

    # An address on one line: c/o, the street, the postcode and the city (as the source writes them)
    def join(v, how)
      return nil unless v.is_a?(Hash)

      town = [v['postal_code'], v['city']].map { |x| x.to_s.strip }.reject(&:empty?).join(' ')
      parts = how == 'postal' && v['care_of'].present? ? ["c/o #{v['care_of'].to_s.strip}"] : []
      (parts + [v['street'].to_s.strip, town]).reject(&:empty?).join(', ').presence
    end

    # ------------------------------------------------------------------ the selection (a general step)

    # The municipalities of the file: { code => { 'name', 'workplaces', 'organizations' } }
    def municipalities(rows)
      out = {}
      rows.select { |r| r['kind'] == 'workplace' }.group_by { |r| r['selection'] }.each do |code, list|
        next if code.blank?

        out[code] = { 'name' => list.first['selection_label'], 'workplaces' => list.size, 'organizations' => list.map { |r| r['parent_key'] }.uniq.size }
      end
      out.sort.to_h
    end

    # The rows inside the selection: workplaces in the codes chosen and each organization that has at least one of
    # them; [rows, workplaces outside]. sole_traders: false leaves sole traders out.
    def select(rows, codes, sole_traders: true)
      codes = Array(codes).map(&:to_s)
      inside = rows.select { |r| r['kind'] == 'workplace' && codes.include?(r['selection']) }
      parents = inside.map { |r| r['parent_key'] }.to_set
      kept = rows.select do |r|
        if r['kind'] == 'organization'
          (parents.include?(r['key']) || r['malformed']) && (sole_traders || !r['sole_trader'])
        else
          codes.include?(r['selection'])
        end
      end
      orgs = kept.select { |r| r['kind'] == 'organization' }.map { |r| r['key'] }.to_set
      kept.reject! { |r| r['kind'] == 'workplace' && !orgs.include?(r['parent_key']) }
      # an organization is read under the municipality of its first workplace inside the selection
      first = inside.each_with_object({}) { |r, h| h[r['parent_key']] ||= r['selection'] }
      kept = kept.map { |r| r['kind'] == 'organization' ? r.merge('selection' => first[r['key']]) : r }
      [kept, rows.count { |r| r['kind'] == 'workplace' } - kept.count { |r| r['kind'] == 'workplace' }]
    end

    def selection_hash(codes, munis)
      vals = Array(codes).map(&:to_s).sort
      { 'by' => mapping.dig('selection', 'by'), 'path' => mapping.dig('selection', 'path'), 'values' => vals,
        'labels' => vals.to_h { |c| [c, munis.dig(c, 'name').to_s] } }
    end

    # ------------------------------------------------------------------ the plan

    def records? = Import.readings?

    # Every row inside the selection with what it would do: 'action' (new, update, unchanged, rejected), 'changes',
    # 'held' (fields that differ but are kept), 'review' (what is never changed by a reading and is shown instead)
    def plan(rows)
      mark_sole_trader_keys!(rows)
      orgs_by_key = {}
      legal = rows.select { |r| r['kind'] == 'organization' && !r['sole_trader'] && !r['malformed'] }.map { |r| r['key'] }
      legal.each_slice(1000) { |s| ::GkPeopleOrganization.where(org_no_digits: s).order(:id).each { |o| orgs_by_key[o.org_no_digits] ||= o } }
      ids = {}
      if records?
        sole = rows.select { |r| r['kind'] == 'organization' && r['sole_trader'] }.map { |r| r['key'] }
        ids.merge!(::GkRecords::Readings.ids_by_source_id('organization', sole, mappings: [MAPPING])) if sole.any?
        cfars = rows.select { |r| r['kind'] == 'workplace' }.filter_map { |r| r['source_id'] }
        cfars.each_slice(1000) { |s| ids.merge!(::GkRecords::Readings.ids_by_source_id('organization', s, mappings: mapping['workplaces_of'])) }
      end
      found = ids.values.uniq.each_slice(1000).flat_map { |s| ::GkPeopleOrganization.where(id: s).to_a }.index_by(&:id)
      existing = orgs_by_key.values + found.values
      origins = records? ? existing.map(&:id).uniq.each_slice(1000).inject({}) { |h, s| h.merge(::GkRecords::Readings.origins_for('organization', s)) } : {}
      seen = {}
      planned = {}
      rows.map do |row|
        r = row.slice('line', 'kind', 'key', 'parent_key', 'selection', 'source_id', 'sole_trader', 'origin')
                .merge('changes' => {}, 'held' => [], 'review' => [], 'adopt' => [], 'errors' => [], 'warnings' => [])
        r['name'] = row.dig('values', 'name')
        if row['malformed']
          r['errors'] << I18n.t(row['kind'] == 'organization' ? :text_gk_people_company_bad_key : :text_gk_people_company_no_cfar)
          r['action'] = 'rejected'
          next r
        end
        if seen[row['key']]
          r['errors'] << I18n.t(:text_gk_people_import_duplicate, line: seen[row['key']])
          r['action'] = 'rejected'
          next r
        end
        seen[row['key']] = row['line']
        rec = if row['kind'] == 'organization'
                row['sole_trader'] ? found[ids[row['key']]] : orgs_by_key[row['key']]
              else
                found[ids[row['source_id']]]
              end
        parent = row['kind'] == 'workplace' ? planned[row['parent_key']] : nil
        plan_row(row, r, rec, origins[rec&.id] || {}, parent)
        planned[row['key']] = r if row['kind'] == 'organization'
        r
      end
    end

    def updatable?(pointer) = pointer && Array(mapping['updates_fields_of']).include?(pointer.reading&.mapping)

    def same?(old, value)
      return old.to_s == value.to_s unless old.is_a?(BigDecimal) || old.is_a?(Date)

      old.is_a?(Date) ? old.iso8601 == value.to_s : old == (BigDecimal(value.to_s) rescue nil)
    end

    # One row against its record (or a new one): the fields set, held or left, and what is to review
    def plan_row(row, r, rec, origins, parent)
      if row['kind'] == 'workplace' && parent && parent['action'] == 'rejected'
        r['errors'] << I18n.t(:text_gk_people_company_parent_rejected, line: parent['line'])
        return r['action'] = 'rejected'
      end
      # a sole trader whose key is new while its workplaces are known: the key changed, nothing is made for it
      if row['kind'] == 'organization' && row['sole_trader'] && rec.nil? && row['known_places']
        r['review'] << { 'field' => 'key', 'reason' => 'sole_trader_key' }
      end
      r['target_id'] = rec&.id
      org = rec || ::GkPeopleOrganization.new
      row['values'].each do |field, value|
        old = org[field]
        if org.new_record?
          org[field] = value
          r['changes'][field] = [nil, org[field]]
          next
        end
        if same?(old, value)
          r['adopt'] << field unless updatable?(origins[field])
          next
        end
        pointer = origins[field]
        # an empty field is filled, as an import fills; one with a value is updated only as this mapping left it
        if old.nil? || (old.is_a?(String) && old.strip.empty?) || (updatable?(pointer) && ::GkRecords::Readings.pointer_holds?(pointer, old))
          org[field] = value
          r['changes'][field] = [old, org[field]]
        else
          r['held'] << { 'field' => field, 'now' => old.is_a?(BigDecimal) ? old.to_s('F') : old.to_s, 'file' => value.to_s,
                         'reason' => pointer ? 'hand' : 'no_pointer' }
        end
      end
      if row['kind'] == 'organization'
        if org.new_record?
          org.active = row['active']
          r['changes']['active'] = [nil, org.active] unless org.active
        elsif org.active != row['active']
          r['review'] << { 'field' => 'active', 'now' => org.active, 'file' => row['active'] }
        end
      elsif rec && parent && parent['target_id'] && rec.parent_id != parent['target_id']
        r['review'] << { 'field' => 'parent', 'now' => rec.parent&.name, 'file' => parent['name'] }
      end
      if r['review'].any? { |x| x['reason'] == 'sole_trader_key' }
        r['action'] = 'unchanged'
        return
      end
      unless org.valid?
        r['errors'].concat(org.errors.full_messages)
        return r['action'] = 'rejected'
      end
      r['action'] = org.new_record? ? 'new' : (r['changes'].any? ? 'update' : 'unchanged')
      r['record'] = org
    end

    COUNT_KEYS = %w[new update unchanged rejected held to_review outside_selection missing moved_out sole_traders].freeze

    def counts(planned, outside: 0, missing: {})
      c = %w[new update unchanged rejected].index_with { |a| planned.count { |x| x['action'] == a } }
      c['held'] = planned.count { |x| x['held'].any? }
      c['to_review'] = planned.count { |x| x['review'].any? }
      c['outside_selection'] = outside
      c['missing'] = missing[:missing].to_i
      c['moved_out'] = missing[:moved_out].to_i
      c['sole_traders'] = planned.count { |x| x['kind'] == 'organization' && x['sole_trader'] && x['action'] != 'rejected' }
      c
    end

    # What readings of this mapping read under the selection and this one does not find: { missing:, moved_out: }
    # (moved out: in the file, outside the selection). Only counted; nothing is changed.
    def missing(codes, read, all_rows)
      return { missing: 0, moved_out: 0 } unless records?

      expected = ::GkRecords::Readings.pointed('organization', mappings: [MAPPING], selection_keys: codes).keys
      in_file = all_rows.flat_map { |r| [r['key'], r['source_id']] }.compact.to_set
      gone = expected.reject { |sid| read.include?(sid) }
      { missing: gone.count { |sid| !in_file.include?(sid) }, moved_out: gone.count { |sid| in_file.include?(sid) } }
    end

    # The keys a plan read (organizations by their number or p_ key, workplaces by their number)
    def read_keys(planned) = planned.reject { |r| r['action'] == 'rejected' }.flat_map { |r| [r['kind'] == 'organization' ? r['key'] : nil, r['source_id']] }.compact.to_set

    # ------------------------------------------------------------------ the import (page and rake)

    # A new import from an uploaded file (the page): the file is read where the upload put it, never into memory.
    def start_upload!(upload, user: ::User.current, manifest: nil, source_label: nil, source_on: nil)
      raise ArgumentError, I18n.t(:error_gk_people_company_admin_only) unless allowed?(user)

      path = upload.respond_to?(:path) ? upload.path : upload.to_s
      name = upload.respond_to?(:original_filename) ? upload.original_filename.to_s : File.basename(path)
      start!(path, name, user: user, manifest: manifest, source_label: source_label, source_on: source_on,
                         max_bytes: limits['page_max_bytes'], max_rows: limits['page_max_rows'], page: true)
    end

    def start!(path, name, user:, manifest:, source_label:, source_on:, max_bytes:, max_rows:, page: false, keep_rows: true)
      # the file's facts, the check against manifest.json and the origin per value are records'
      raise ArgumentError, I18n.t(:error_gk_people_company_records) unless records?

      facts = ::GkRecords::Readings.file_facts_path(path).merge('file' => File.basename(name.to_s.tr('\\', '/')))
      manifest = Import.parse_manifest(manifest)
      entry = manifest ? ::GkRecords::Readings.check_manifest!(manifest, facts['file'], sha256: facts['sha256']) : nil
      source_label = source_label.to_s.strip.presence || entry&.dig('source').presence || manifest&.dig('source').presence || DEFAULT_SOURCE
      source_on = source_on.presence || facts['file'][/(\d{8})/, 1]&.then { |d| (Date.strptime(d, '%Y%m%d') rescue nil) }
      read = scan(path, max_bytes: max_bytes, max_rows: max_rows, page: page)
      import = ::GkPeopleImport.new(resource: 'organizations', user_id: user&.logged? ? user.id : nil, filename: facts['file'][0, 255],
                                    source_label: source_label, source_on: source_on, mode: 'fill', created_at: Time.current)
      import.options = { 'profile' => PROFILE, 'file' => facts, 'manifest' => ::GkRecords::Readings.trim_manifest(manifest),
                         'municipalities' => read[:municipalities], 'lines' => read[:lines], 'sole_traders' => true }.compact
      import.rows_json = { 'rows' => keep_rows ? read[:rows] : [] }.to_json
      import.save!
      [import, read[:rows]]
    end

    # A new preview for the selection chosen (codes) and the choice on sole traders; nothing is planned without a
    # selection
    def choose!(import, codes:, sole_traders: true, rows: nil)
      codes = Array(codes).map(&:to_s).reject(&:empty?) & import.options.fetch('municipalities', {}).keys
      import.options = import.options.merge('selection' => codes.presence, 'sole_traders' => sole_traders ? true : false)
      import.save!
      refresh!(import, rows: rows)
    end

    # The preview kept on the import: only the rows that would do something, with the counts
    def refresh!(import, rows: nil)
      all = rows || import.raw_rows
      codes = Array(import.options['selection'])
      if codes.empty?
        import.update!(counts_json: {}.to_json, rows_json: { 'rows' => all, 'preview' => [] }.to_json)
        return []
      end
      kept, outside = select(all, codes, sole_traders: import.options['sole_traders'] != false)
      planned = plan(kept)
      c = counts(planned, outside: outside, missing: missing(codes, read_keys(planned), all))
      store = planned.reject { |x| x['action'] == 'unchanged' && x['held'].empty? && x['review'].empty? }.map { |x| x.except('record') }
      import.update!(counts_json: c.to_json, rows_json: { 'rows' => rows ? [] : all, 'preview' => store }.to_json)
      planned
    end

    # Rows written per transaction (each row has a savepoint of its own, so one that fails leaves the others)
    BATCH = 500

    # The run: a reading in records with the selection, the rows written a batch at a time, the fields pointing to the
    # reading with their source, the source's time and the municipality they were read under (records' set_many!, a
    # statement per thousand pointers). progress: called with (rows done, rows) after each batch.
    def run!(import, user: ::User.current, rows: nil, progress: nil)
      raise ArgumentError, 'state' unless import.state == 'preview'
      raise ArgumentError, I18n.t(:error_gk_people_company_admin_only) unless allowed?(user)

      codes = Array(import.options['selection'])
      raise ArgumentError, I18n.t(:text_gk_people_import_selection_required) if codes.empty?

      all = rows || import.raw_rows
      kept, outside = select(all, codes, sole_traders: import.options['sole_traders'] != false)
      planned = plan(kept)
      reading = start_reading!(import, planned, codes, user)
      log = ::GkPeopleSyncLog.create!(source: 'import', resource: 'organizations', user_id: user&.logged? ? user.id : nil,
                                      started_at: Time.current, received: planned.size)
      made = {}
      done = 0
      Import.within(import, reading) do
        planned.each_slice(BATCH) do |batch|
          pointers = []
          ::ActiveRecord::Base.transaction do
            batch.each do |r|
              rec = write_row!(r, made, user)
              pointers.concat(pointers_for(rec, r)) if rec&.persisted?
            end
            ::GkRecords::Readings.set_many!(reading, pointers) if reading
          end
          done += batch.size
          progress&.call(done, planned.size)
        end
      end
      c = counts(planned, outside: outside, missing: missing(codes, read_keys(planned), all))
      errors = planned.select { |r| r['action'] == 'rejected' }.map { |r| { line: r['line'], errors: r['errors'] } }
      log.update!(finished_at: Time.current, created: c['new'], updated: c['update'], unchanged: c['unchanged'], rejected: c['rejected'],
                  errors_json: errors.to_json)
      if reading
        ::GkRecords::Readings.finish!(reading, counts: { 'added' => c['new'], 'changed' => c['update'], 'unchanged' => c['unchanged'],
                                                          'rejected' => c['rejected'], 'held' => c['held'], 'to_review' => c['to_review'],
                                                          'missing' => c['missing'] }, rows: planned.size)
      end
      store = planned.reject { |x| x['action'] == 'unchanged' && x['held'].empty? && x['review'].empty? }.map { |x| x.except('record', 'origin') }
      import.options = import.options.merge('reading_id' => reading&.id).compact
      import.update!(state: 'done', finished_at: Time.current, sync_log_id: log.id, counts_json: c.to_json,
                     rows_json: { 'preview' => store }.to_json)
      c
    end

    def start_reading!(import, planned, codes, user)
      return nil unless records?

      ::GkRecords::Readings.start!(target_type: 'organization', source_label: import.source_label, route: 'file', format: 'jsonl',
                                    source_time: import.source_on, user: user, mode: 'once', files: [import.options['file']].compact,
                                    manifest: import.manifest, mapping: MAPPING, rows: planned.size, origin: 'import',
                                    selection: selection_hash(codes, import.options.fetch('municipalities', {})))
    end

    # One row written (a new workplace under the organization the run made or found for it); its record, or nil when
    # it was rejected
    def write_row!(r, made, user)
      rec = r.delete('record')
      rec.parent_id = made[r['parent_key']]&.id if r['kind'] == 'workplace' && rec&.new_record?
      if %w[new update].include?(r['action']) && rec
        ok = ::ActiveRecord::Base.transaction(requires_new: true) do
          rec.created_by_id ||= user.id if rec.new_record? && user&.logged?
          rec.save
        end
        unless ok
          r['action'] = 'rejected'
          r['errors'] = rec.errors.full_messages
          return nil
        end
        r['target_id'] = rec.id
      end
      rec ||= r['target_id'] && ::GkPeopleOrganization.find_by(id: r['target_id'])
      made[r['key']] = rec if r['kind'] == 'organization' && rec&.persisted?
      rec
    end

    # The pointers of a row for records' set_many!: the fields it set (and those it found as the file says, never
    # pointed by this mapping), a group per source and time; the source's id with the municipality it was read under
    def pointers_for(rec, r)
      origin = r['origin'] || {}
      fields = (r['changes'].keys + r['adopt']).uniq
      out = fields.group_by { |f| origin[f] || [nil, nil] }.map do |(src, time), group|
        { obj: rec, fields: group, source: src, source_time: time.presence && Time.zone.parse(time.to_s) }
      end
      sid = r['kind'] == 'organization' ? r['key'] : r['source_id']
      out << { obj: rec, fields: ['source_id'], source_id: sid, values: { 'source_id' => sid }, selection_key: r['selection'] } if sid
      out
    end

    # ------------------------------------------------------------------ rake

    # The rake tasks' run: the same reading, preview and run as the page, the rows held in memory. commit: false rolls
    # everything back (the import too). Returns { counts:, import:, preview: }.
    def run_path!(path, codes:, login:, manifest: nil, commit: false, sole_traders: true, source: nil, source_on: nil, progress: nil)
      user = ::User.find_by(login: login.to_s)
      raise ArgumentError, I18n.t(:error_gk_people_company_admin_only) unless user && allowed?(user)

      result = nil
      ::ActiveRecord::Base.transaction do
        ::User.current = user
        import, rows = start!(path, File.basename(path), user: user, manifest: manifest, source_label: source, source_on: source_on,
                                                       max_bytes: limits['max_bytes'], max_rows: limits['max_rows'], keep_rows: false)
        planned = choose!(import, codes: codes, sole_traders: sole_traders, rows: rows)
        preview = planned.map { |x| x.except('record') }
        counts = commit ? run!(import, user: user, rows: rows, progress: progress) : import.counts
        result = { counts: counts, import: import, preview: preview, municipalities: import.options['municipalities'] }
        raise ::ActiveRecord::Rollback unless commit
      end
      result
    end

    # A sole trader's workplaces known while its key is not: the key changed (the person key was lost), so it is held
    def mark_sole_trader_keys!(rows)
      return rows unless records?

      cfars = rows.select { |r| r['kind'] == 'workplace' }.filter_map { |r| r['source_id'] }
      known = cfars.each_slice(1000).inject({}) { |h, s| h.merge(::GkRecords::Readings.ids_by_source_id('organization', s, mappings: mapping['workplaces_of'])) }
      rows.select { |r| r['kind'] == 'workplace' && known.key?(r['source_id']) }.map { |r| r['parent_key'] }.uniq.each do |k|
        rows.each { |r| r['known_places'] = true if r['kind'] == 'organization' && r['sole_trader'] && r['key'] == k }
      end
      rows
    end

    # ------------------------------------------------------------------ the controller of the personal data

    # The organization the setting names as controller, or nil
    def data_controller
      id = (::Setting.plugin_gk_people['data_controller_org_id'] rescue nil).to_s
      id.match?(/\A\d+\z/) ? ::GkPeopleOrganization.find_by(id: id.to_i) : nil
    end

    def data_controller_text
      org = data_controller
      org ? I18n.t(:text_gk_people_data_controller, organisation: org.name) : I18n.t(:text_gk_people_data_controller_missing)
    end
  end
end
