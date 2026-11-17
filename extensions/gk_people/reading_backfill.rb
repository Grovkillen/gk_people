# frozen_string_literal: true

module GkPeople
  # Readings in hindsight: every import run before readings existed gets one reading in records, route file, mode once,
  # without files, marked "i efterhand", with the import's source, the date of its facts and its time; and the fields its
  # rows set point to it (without the value's digest, which it does not know), unless a later reading already moved the
  # pointer. info_source is never changed or removed. Run once after the upgrade (a marker in the plugin's settings),
  # from after_initialize and from the scenario's import step; an import that has its reading is never given another,
  # so a second run changes nothing.
  module ReadingBackfill
    MARKER = 'readings_backfilled'

    module_function

    def ready?
      return false unless defined?(::GkRecords::Readings) && GkPeople.records?

      ::GkRecords::Readings.ready? && ::GkPeopleImport.table_exists?
    rescue StandardError
      false
    end

    def settings = (::Setting.plugin_gk_people.is_a?(Hash) ? ::Setting.plugin_gk_people : {})
    def done? = settings[MARKER].to_s == '1'

    # Once per installation; true when it ran now
    def run_once!
      return false if !ready? || done?

      run!
      ::Setting.plugin_gk_people = settings.merge(MARKER => '1')
      true
    rescue StandardError => e
      Rails.logger.warn("[gk_people] readings in hindsight not made (#{e.class}: #{e.message})")
      false
    end

    # Every import that was run and has no reading, oldest first (so the latest one's pointers win). Returns how many
    # readings were made.
    def run!
      ::GkPeopleImport.where(state: 'done').order(:finished_at, :id).to_a.count { |imp| for_import(imp) }
    end

    # The reading for one import, or nil when it has one already
    def for_import(import)
      reading = nil
      ::GkPeopleImport.transaction do
        import.lock!
        next if import.reading_id

        at = import.finished_at || import.created_at || Time.current
        model = import.resource == 'organizations' ? ::GkPeopleOrganization : ::GkPeoplePerson
        c = import.counts
        reading = ::GkRecords::Readings.start!(target_type: import.resource == 'organizations' ? 'organization' : 'person',
                                                source_label: import.source_label, route: 'file', format: 'csv', source_time: import.source_on,
                                                user: import.user, mode: 'once', made_afterwards: true, read_at: at,
                                                rows: import.preview_rows.size, origin: 'system')
        ::GkRecords::Readings.finish!(reading, counts: { 'added' => c['new'].to_i, 'changed' => c['update'].to_i,
                                                          'unchanged' => c['unchanged'].to_i + c['skipped'].to_i, 'rejected' => c['rejected'].to_i },
                                                rows: import.preview_rows.size)
        import.preview_rows.each do |r|
          next unless %w[new update].include?(r['action']) && r['target_id']

          obj = model.find_by(id: r['target_id']) or next
          fields = (r['changes'] || {}).keys.map { |f| Import::POINTER_FIELD.fetch(f, f) }
          ::GkRecords::Readings.set!(reading, obj, fields, at: at, only_newer: true, digest: false) if fields.any?
        end
        import.options = import.options.merge('reading_id' => reading.id)
        import.update_columns(options_json: import.options_json)
      end
      reading
    end
  end
end
