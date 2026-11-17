# frozen_string_literal: true

# An import of organizations or persons from a CSV file: the parsed rows, where the facts come from, the mapping
# of columns and the mode, and the preview until it is run. A done import keeps what each row did; one left in
# preview can be discarded.
class GkPeopleImport < ApplicationRecord
  self.table_name = 'gk_people_imports'

  belongs_to :user, optional: true
  belongs_to :sync_log, class_name: 'GkPeopleSyncLog', optional: true

  validates :resource, inclusion: { in: GkPeople::Import::RESOURCES }
  validates :mode, inclusion: { in: GkPeople::Import::MODES }
  validates :source_label, presence: true, length: { maximum: 200 }
  validates :state, inclusion: { in: %w[preview done discarded] }

  before_validation { self.source_label = source_label.to_s.strip }

  scope :sorted, -> { order(created_at: :desc, id: :desc) }

  def options = (@options ||= (JSON.parse(options_json.presence || '{}') rescue {}))

  def options=(h)
    @options = h
    self.options_json = h.to_json
  end

  def options_json=(v)
    @options = nil
    super
  end

  def headings = Array(options['headings'])
  def separator = options['separator'].to_s

  # { field => column index }
  def mapping = (options['mapping'] || {}).transform_values(&:to_i)

  def mapping=(m)
    self.options = options.merge('mapping' => m)
  end

  def data = (@data ||= (JSON.parse(rows_json.presence || '{}') rescue {}))
  def raw_rows = Array(data['rows'])
  def preview_rows = Array(data['preview'])
  def counts = (JSON.parse(counts_json.presence || '{}') rescue {})

  def rows_json=(v)
    @data = nil
    super
  end

  def preview? = state == 'preview'

  # The source's manifest given with the file, the file's layout (scb_workplaces for SCB's CSV of workplaces) and the
  # reading in records the run made (or the one made in hindsight)
  def manifest = options['manifest']
  def profile = options['profile'].to_s
  # Company data (Get-Foretagsdata.ps1's JSONL), read by GkPeople::CompanyData
  def company? = profile == GkPeople::CompanyData::PROFILE
  def reading_id = options['reading_id']&.to_i
  def reading = (defined?(::GkRecordsReading) && reading_id ? ::GkRecordsReading.find_by(id: reading_id) : nil)

  # The headings no field reads (the preview says so)
  def unread_headings
    used = mapping.values
    headings.each_with_index.reject { |_h, i| used.include?(i) }.map { |h, i| h.presence || (i + 1).to_s }
  end
end
