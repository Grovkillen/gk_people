# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'

module GkPeople
  module Scenarios
    # Company data in scenarios. Every file is made up: organization numbers with a wrong check digit, made-up names,
    # places inside the scenario's made-up area; the one personal number in a test is the tax agency's published test
    # number. Never a real file.
    # * step people_company_data (order 166): people.data_controller names the scenario's organization the import page
    #   names as controller; people.company_data: [{ key, by, file, selection: [codes], sole_traders }] reads each file
    #   (its lines in the locale under people.company_data.<key>.jsonl) with a manifest made here the way
    #   Get-Foretagsdata.ps1 writes one (with the computer, errors, a summary and its sources, which are never kept)
    # * expectation ppl_company_data: <part> (see company_data_check)
    # * company_data_volume: a large made-up file and its manifest, for the volume test (rake gk_people:foretagsdata:generate)
    TEST_PNR = '19121212-1212'

    def self.register_company_data_scenarios!
      ::GkScenarios::Steps.register('people_company_data', plugin: :gk_people, order: 166) do |ctx|
        data = ctx.scenario.data['people'] || {}
        set_data_controller!(ctx, data['data_controller']) if data['data_controller']
        Array(data['company_data']).each do |cd|
          next if cd['run'] == false

          user = cd['by'] ? ctx.get(:user, cd['by']) : first_admin
          path = company_file(ctx, cd)
          ctx.as(user) do
            imp = company_import!(path, user, company_manifest(path), cd['selection'], cd['sole_traders'] != false)
            CompanyData.run!(imp, user: user)
            ctx.note(:people_company_data, cd['key'], imp, true)
          end
        end
      end

      ::GkScenarios::Expect.register('ppl_company_data') do |ctx, e|
        company_data_check(ctx, e)
      rescue StandardError => ex
        { 'ok' => false, 'want' => e['ppl_company_data'].to_s, 'got' => "#{ex.class}: #{ex.message}"[0, 300] }
      end
    end

    def self.first_admin = ::User.active.where(admin: true).order(:id).first

    def self.set_data_controller!(ctx, key)
      org = scenario_org(ctx, key)
      return unless org

      now = ::Setting.plugin_gk_people.is_a?(Hash) ? ::Setting.plugin_gk_people.dup : {}
      return if now['data_controller_org_id'].to_s == org.id.to_s

      ::Setting.plugin_gk_people = now.merge('data_controller_org_id' => org.id.to_s)
    end

    def self.scratch_dir
      dir = ::Rails.root.join('tmp', 'gk_scenarios', 'company_data').to_s
      FileUtils.mkdir_p(dir)
      dir
    end

    # The scenario's made-up file, written where the instance keeps its temporary files
    def self.company_file(ctx, cd)
      path = File.join(scratch_dir, File.basename((cd['file'].presence || "#{cd['key']}.jsonl").to_s))
      File.write(path, ctx.scenario.t(:people, :company_data, cd['key'], :jsonl).to_s, mode: 'wb')
      path
    end

    # A manifest as Get-Foretagsdata.ps1 writes one, with what a reading must never keep
    def self.company_manifest(path, sha256: nil)
      lines = File.foreach(path).count { |l| l.strip != '' }
      day = (File.basename(path)[/(\d{8})/, 1] || '20261005')
      at = "#{day[0, 4]}-#{day[4, 2]}-#{day[6, 2]}T07:00:00+02:00"
      { 'script' => 'Get-Foretagsdata.ps1', 'revision' => '0.00.012', 'result' => 'ok', 'computer' => 'PROVDATOR',
        'errors' => ['påhittat fel'], 'summary' => { 'organisations' => lines }, 'start' => at, 'end' => at,
        'sources' => { 'SCB' => { 'api' => 'AFR API v1' }, 'Bolagsverket' => { 'api' => 'Värdefulla datamängder v1' } },
        'files' => [{ 'file' => "ut\\#{File.basename(path)}", 'kind' => 'foretagsdata', 'source' => 'SCB och Bolagsverket, sammanslagna',
                      'format' => 'JSONL; UTF-8', 'retrieved' => at, 'rows' => lines, 'size' => File.size(path),
                      'sha256' => sha256 || Digest::SHA256.file(path).hexdigest }] }
    end

    def self.company_import!(path, user, manifest, codes, sole_traders = true)
      lim = CompanyData.limits
      imp, = CompanyData.start!(path, File.basename(path), user: user, manifest: manifest, source_label: nil, source_on: nil,
                                                         max_bytes: lim['page_max_bytes'], max_rows: lim['page_max_rows'])
      CompanyData.choose!(imp, codes: Array(codes), sole_traders: sole_traders)
      imp
    end

    def self.company_imports(file) = ::GkPeopleImport.where(filename: file.to_s).sorted.select(&:company?)

    def self.org_by_number(no) = ::GkPeopleOrganization.by_number(no.to_s).order(:id).first

    def self.workplace(cfar)
      id = ::GkRecords::Readings.ids_by_source_id('organization', [cfar.to_s], mappings: [CompanyData::MAPPING])[cfar.to_s]
      id && ::GkPeopleOrganization.find_by(id: id)
    end

    # A made-up line of company data
    def self.company_line(org_number, name: 'Prov AB', sole: false, places: [['90000901', '2305', 'Bräcke']])
      { 'org_number' => org_number, 'sole_trader' => sole,
        'attributes' => sole ? {} : { 'name' => { 'value' => name, 'source' => 'Bolagsverket' } },
        'workplaces' => places.map { |cfar, code, city| { 'source' => 'SCB', 'cfar_number' => cfar, 'name' => name, 'municipality' => { 'code' => code, 'name' => city } } },
        'sources' => { 'Bolagsverket' => { 'status' => 'found', 'retrieved' => '2026-10-05T06:00:00+02:00' } } }.to_json
    end

    def self.write_lines(name, lines)
      path = File.join(scratch_dir, name)
      File.write(path, "#{lines.join("\n")}\n", mode: 'wb')
      path
    end

    # Each refusal: nothing is made, and the message names the line, never the value
    def self.refused(path, user, manifest: :make, value: nil)
      before = [::GkPeopleImport.count, ::GkPeopleOrganization.count]
      msg = begin
        company_import!(path, user, manifest == :make ? company_manifest(path) : manifest, %w[2305])
        nil
      rescue ArgumentError => ex
        ex.message
      end
      [msg.present?, msg.to_s, [::GkPeopleImport.count, ::GkPeopleOrganization.count] == before && (value.nil? || !msg.to_s.include?(value))]
    end

    # ppl_company_data: <part>, import: <key> (the scenario's company_data key), and per part:
    # * reading: the import done, its reading with the mapping, the file's facts and no file, the selection, the
    #   manifest without the computer, the errors, the summary or the sources object; counts: { ... } as given
    # * origin: org: <number> has its name from Bolagsverket with the time the facts were fetched, cfar: <number> its
    #   name from SCB with the workplace's number as the source's id; digests, never values
    # * hierarchy: the workplaces cfars: [...] are children of org; not_read: <cfar> was not read
    # * new_inactive: org was made inactive, with its form and the day it was deregistered
    # * hand_kept: org's field: holds value: (a hand-written value kept), and it is still active
    # * sole_trader: key: <p_ key> is only a pointer's source id; its organization has no number and not the name decoy:
    # * no_personal_number: nothing like a personal number in people's organizations and imports or records' readings
    # * never_read: no telephone or e-mail on any organization the reading made
    # * again (rolled back): org's city written by hand, then the second file (second:) read: counts as given, the city kept
    # * refused_pnr, refused_text, refused_masked, refused_sole_key, refused_sha, refused_json (rolled back): the file
    #   is refused, nothing is made, and the message names the line, never the value
    # * admin_only (as: a user who may change the registers but is no administrator), selection_required, limits,
    #   rake_same, data_controller (rolled back)
    def self.company_data_check(ctx, e)
      part = e['ppl_company_data'].to_s
      cd = Array((ctx.scenario.data['people'] || {})['company_data']).detect { |x| x['key'] == e['import'].to_s }
      admin = first_admin
      checks = []
      result = nil
      ::ActiveRecord::Base.transaction(requires_new: true) do
        ::User.current = admin
        case part
        when 'reading'
          imp = cd && company_imports(cd['file']).first
          rd = imp&.reading
          m = rd&.manifest || {}
          checks << ['the import done', imp&.state == 'done']
          checks << ['mapping and file facts', rd && rd.mapping == CompanyData::MAPPING && rd.files.size == 1 && rd.files.first['sha256'].to_s.match?(/\A\h{64}\z/)]
          checks << ['no file kept', ::Attachment.where(container_type: 'GkRecordsReading').none? && !imp.rows_json.to_s.include?('"attributes"')]
          checks << ['selection', rd&.selection&.dig('values') == Array(cd['selection']).map(&:to_s).sort]
          checks << ['manifest trimmed', !m.key?('computer') && !m.key?('errors') && !m.key?('summary') && !m.key?('sources') && m['files'].to_a.all? { |f| !f['file'].to_s.include?('\\') }]
          (e['counts'] || {}).each { |k, v| checks << ["#{k} #{v} (#{imp&.counts&.dig(k.to_s)})", imp&.counts&.dig(k.to_s).to_i == v.to_i] }
        when 'origin'
          org = org_by_number(e['org'])
          o = org && ::GkRecords::Readings.origin(org, 'name')
          checks << ['name from Bolagsverket', o && o[:source] == 'Bolagsverket' && o[:source_time] && o[:reading]&.mapping == CompanyData::MAPPING]
          checks << ['the digest, never the value', o && o[:value_sha256] == ::GkRecords::Readings.value_digest(org.name) && o[:value_sha256] != org.name]
          wp = workplace(e['cfar'])
          w = wp && ::GkRecords::Readings.origin(wp, 'name')
          checks << ['workplace from SCB', w && w[:source] == 'SCB']
          s = wp && ::GkRecords::Readings.origin(wp, 'source_id')
          checks << ['the workplace number as source id, under its municipality', s && s[:source_id] == e['cfar'].to_s && s[:pointer].selection_key == '2305']
        when 'hierarchy'
          org = org_by_number(e['org'])
          kids = Array(e['cfars']).map { |c| workplace(c) }
          checks << ['workplaces under the organization', org && kids.all? { |k| k && k.parent_id == org.id }]
          checks << ['outside the selection not read', workplace(e['not_read']).nil?] if e['not_read']
          checks << ['coordinates', kids.first&.location_crs == 'EPSG:3006' && kids.first&.location_n.present?]
        when 'new_inactive'
          org = org_by_number(e['org'])
          checks << ['made inactive', org && !org.active]
          checks << ['form and deregistration', org&.org_form.present? && org&.deregistered_on.present?]
        when 'hand_kept'
          org = org_by_number(e['org'])
          checks << ["#{e['field']} kept", org && org[e['field']].to_s == e['value'].to_s]
          checks << ['still active', org&.active]
          imp = cd && company_imports(cd['file']).first
          rows = imp ? imp.preview_rows.select { |r| r['key'] == e['org'].to_s.gsub(/\D/, '') } : []
          checks << ['held and to review shown', rows.any? { |r| Array(r['held']).any? { |h| h['field'] == e['field'] } } && rows.any? { |r| Array(r['review']).any? }]
        when 'sole_trader'
          rows = ::GkRecordsFieldOrigin.where(target_type: 'organization', source_id: e['key'].to_s)
          org = rows.first && ::GkPeopleOrganization.find_by(id: rows.first.target_id)
          checks << ['found by its key', org.present?]
          checks << ['no number, not the decoy name', org && org.org_no.nil? && org.name != e['decoy']]
          checks << ['the key nowhere else', ::GkPeopleOrganization.where('name LIKE ? OR notes LIKE ? OR info_source LIKE ?', "%#{e['key']}%", "%#{e['key']}%", "%#{e['key']}%").none?]
        when 'no_personal_number'
          texts = ::GkPeopleOrganization.pluck(:name, :address, :city, :notes, :info_source).flatten +
                  ::GkPeopleImport.pluck(:rows_json, :options_json).flatten +
                  ::GkRecordsReading.pluck(:manifest_json, :selection_json, :files_json).flatten +
                  ::GkRecordsFieldOrigin.where(target_type: 'organization').pluck(:source_id)
          # checksums are hex, and a run of digits in one can look like a date by chance
          checks << ['nothing like a personal number', texts.compact.none? { |t| CompanyData.personal_number?(t.to_s.gsub(/\h{32,}/, '')) }]
        when 'never_read'
          imp = cd && company_imports(cd['file']).first
          # the organizations the reading made (one written by hand may have a telephone of its own)
          ids = imp ? imp.preview_rows.select { |r| r['action'] == 'new' }.filter_map { |r| r['target_id'] } : []
          checks << ['no telephone or e-mail', ids.any? && ::GkPeopleOrganization.where(id: ids).where("COALESCE(phone, '') <> '' OR COALESCE(email, '') <> ''").none?]
        when 'again'
          org = org_by_number(e['org'])
          org.update!(city: e['hand_city'])
          second = Array((ctx.scenario.data['people'] || {})['company_data']).detect { |x| x['key'] == e['second'].to_s }
          path = company_file(ctx, second)
          imp = company_import!(path, admin, company_manifest(path), second['selection'])
          c = CompanyData.run!(imp, user: admin)
          (e['counts'] || {}).each { |k, v| checks << ["#{k} #{v} (#{c[k.to_s]})", c[k.to_s].to_i == v.to_i] }
          checks << ['the hand-written city kept', org.reload.city == e['hand_city']]
          checks << ['a second reading', imp.reload.reading && imp.reading_id != company_imports(cd['file']).first&.reading_id]
        when 'refused_pnr'
          path = write_lines('refused_pnr.jsonl', [company_line('5560000321'), company_line('197001010000')])
          refused_checks(checks, refused(path, admin, value: '197001010000'), 'rad 2')
        when 'refused_text'
          path = write_lines('refused_text.jsonl', [company_line('5560000321', name: "Prov #{TEST_PNR}")])
          refused_checks(checks, refused(path, admin, value: '1212'), 'rad 1')
        when 'refused_masked'
          path = write_lines('refused_masked.jsonl', [company_line('5560000321'), company_line('700101XXXX')])
          refused_checks(checks, refused(path, admin, value: 'XXXX'), 'rad 2')
        when 'refused_sole_key'
          path = write_lines('refused_sole.jsonl', [company_line('5560000321', sole: true)])
          refused_checks(checks, refused(path, admin, value: '5560000321'), 'rad 1')
        when 'refused_sha'
          path = write_lines('refused_sha.jsonl', [company_line('5560000321')])
          refused_checks(checks, refused(path, admin, manifest: company_manifest(path, sha256: 'f' * 64)), 'SHA-256')
        when 'refused_json'
          path = write_lines('refused_json.jsonl', [company_line('5560000321'), '{"org_number": "5560000322", '])
          refused_checks(checks, refused(path, admin), 'rad 2')
        when 'admin_only'
          user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as']))
          path = write_lines('admin_only.jsonl', [company_line('5560000321')])
          ok = begin
            CompanyData.start_upload!(path, user: user)
            false
          rescue ArgumentError
            true
          end
          checks << ['refused for one who is no administrator', user && !user.admin? && ok]
        when 'selection_required'
          path = write_lines('selection.jsonl', [company_line('5560000321')])
          imp = company_import!(path, admin, company_manifest(path), [])
          ok = begin
            CompanyData.run!(imp, user: admin)
            false
          rescue ArgumentError
            true
          end
          checks << ['no run without a selection', ok && imp.counts.empty?]
        when 'limits'
          path = write_lines('limits.jsonl', [company_line('5560000321'), company_line('5560000322', places: [%w[90000902 2305 Bräcke]])])
          ok = begin
            CompanyData.scan(path, max_rows: 1, page: true)
            false
          rescue ArgumentError => ex
            ex.message.include?('rake') || ex.message.include?('gk_people:foretagsdata')
          end
          checks << ['over the limit refused, with the rake command', ok]
        when 'rake_same'
          path = company_file(ctx, cd)
          page = company_import!(path, admin, company_manifest(path), cd['selection']).counts
          rake = CompanyData.run_path!(path, codes: cd['selection'], login: admin.login, manifest: company_manifest(path), commit: false)[:counts]
          checks << ['the same counts by rake as on the page', page.present? && page == rake]
          checks << ['a synced folder is named', CompanyData.synced_path?('C:/Users/x/Dropbox/data/f.jsonl') && !CompanyData.synced_path?(path)]
        when 'data_controller'
          org = scenario_org(ctx, e['org'])
          checks << ['the controller named', org && CompanyData.data_controller_text.include?(org.name)]
          # without a controller for the check; GK Scenarios writes back and empties core's cache of settings
          ::GkScenarios::Expect.with_setting(:gk_people, 'data_controller_org_id' => '') do
            checks << ['not given, said so', CompanyData.data_controller_text == I18n.t(:text_gk_people_data_controller_missing)]
          end
        else
          checks << ["unknown part #{part}", false]
        end
        result = scenario_result(checks)
        raise ::ActiveRecord::Rollback
      end
      result
    end

    def self.refused_checks(checks, (refused, msg, clean), line)
      checks << ['refused', refused]
      checks << ["the message names #{line}", msg.include?(line.split.last)]
      checks << ['nothing made, no value in the message', clean]
    end

    # A large made-up file and its manifest (the volume test): organization numbers with a wrong check digit, about a
    # tenth sole traders with made-up keys, one to four workplaces each, some outside the first municipality, places
    # inside a made-up rectangle, telephone and e-mail filled to show they are never read. [file, manifest]
    def self.company_data_volume(out, rows: 20_000, seed: 128, codes: %w[2305 2380])
      rnd = Random.new(seed)
      FileUtils.mkdir_p(File.dirname(out))
      cfar = 80_000_000
      File.open(out, 'wb') do |f|
        rows.times do |i|
          sole = (i % 10) == 9
          number = sole ? "p_#{Digest::SHA256.hexdigest("prov-#{seed}-#{i}")[0, 16]}" : made_up_number(i)
          places = Array.new(1 + rnd.rand(4)) do
            cfar += 1
            code = codes[rnd.rand(codes.size)]
            { 'source' => 'SCB', 'cfar_number' => cfar.to_s, 'name' => "Provställe #{cfar}", 'municipality' => { 'code' => code, 'name' => "Provkommun #{code}" },
              'size_class' => '1-4 anställda', 'industries' => [{ 'code' => '25620', 'rank' => 1 }],
              'visiting_address' => { 'street' => "Provgatan #{rnd.rand(100)}", 'postal_code' => '840 60', 'city' => 'PROVORT' },
              'phone' => '0600-000000', 'email' => 'prov@example.invalid', 'opt_outs' => { 'advertising' => 'Reklamspärr' },
              'coordinates' => { 'reference_system' => 'SWEREF 99 TM (EPSG:3006)', 'n' => 6_950_000 + rnd.rand(20_000), 'e' => 500_000 + rnd.rand(30_000) } }
          end
          attrs = sole ? {} : { 'name' => { 'value' => "Provbolag #{i} AB", 'source' => 'Bolagsverket' },
                                'organisation_form' => { 'value' => 'Aktiebolag', 'source' => 'SCB, genom Bolagsverket' },
                                'active' => { 'value' => (i % 50) != 0, 'source' => 'Bolagsverket' },
                                'postal_address' => { 'value' => { 'street' => 'Box 1', 'postal_code' => '840 60', 'city' => 'PROVORT', 'country' => 'Sverige' }, 'source' => 'Bolagsverket' } }
          line = { 'org_number' => number, 'sole_trader' => sole, 'attributes' => attrs, 'workplaces' => places,
                   'sources' => { 'Bolagsverket' => { 'status' => sole ? 'not_asked_personal_identity_number' : 'found', 'retrieved' => '2026-10-05T06:00:00+02:00' },
                                  'SCB' => { 'files' => codes.map { |c| { 'file' => "afr_kommun_#{c}.json", 'retrieved' => '2026-10-05T05:00:00+02:00' } } } } }
          f.write(line.to_json)
          f.write("\r\n")
        end
      end
      manifest = File.join(File.dirname(out), "#{File.basename(out, '.jsonl')}_manifest.json")
      File.write(manifest, JSON.pretty_generate(company_manifest(out)), mode: 'wb')
      [out, manifest]
    end

    # Ten digits that are no organization number: the third digit 2 or more, as an organization number's, and the check
    # digit one off
    def self.made_up_number(i)
      base = format('556%06d', i)
      sum = base.chars.each_with_index.sum do |c, n|
        v = c.to_i * (n.even? ? 2 : 1)
        v > 9 ? v - 9 : v
      end
      right = (10 - (sum % 10)) % 10
      "#{base}#{(right + 1) % 10}"
    end
  end
end
