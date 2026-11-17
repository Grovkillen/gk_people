# frozen_string_literal: true

# A group of people (plugins/people, groups): persons, with or without accounts, gathered for quick picks and
# mailings. Not a Redmine group (those give permissions and hold accounts). Inactive instead of deleted.
class GkPeopleGroup < ApplicationRecord
  self.table_name = 'gk_people_groups'
  # instants with their zone
  GkPeopleInstant.attributes!(self, :synced_at, :external_deleted_at)

  has_many :memberships, -> { order(:position, :id) }, class_name: 'GkPeopleGroupMember', foreign_key: :group_id
  has_many :persons, through: :memberships
  belongs_to :created_by, class_name: 'User', optional: true

  validates :name, presence: true, length: { maximum: 200 }, uniqueness: { case_sensitive: false, conditions: -> { where(active: true) }, if: :active }
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true

  before_validation { self.name = name.to_s.strip }
  after_create_commit { GkPeople::PersonGroups.write(self, 'person_group_created', { name: name, source: source }) }
  after_update_commit :changed_event

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(Arel.sql('lower(gk_people_groups.name)')) }

  def self.search(term) = where(GkPeople::Sql.like(arel_table[:name], term))

  def to_s = name.to_s
  def synced? = source.present?

  # The source owns a synced group's name, active and members (GkPeople::Sync); the description is local
  SOURCE_OWNS = %w[name active members].freeze
  def owned_by_source?(attr) = synced? && SOURCE_OWNS.include?(attr.to_s)

  private

  def changed_event
    ch = saved_changes.slice('name', 'description', 'active')
    GkPeople::PersonGroups.write(self, 'person_group_changed', ch) if ch.any?
  end
end
