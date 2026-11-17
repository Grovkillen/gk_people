# frozen_string_literal: true

# A responsibility (GkPeople::Responsibilities): data, never code. The kind decides how many may hold it in a scope
# (function: one; area: several; object: one per object, once cmdb is there).
class GkPeopleResponsibility < ApplicationRecord
  self.table_name = 'gk_people_responsibilities'

  has_many :assignments, class_name: 'GkPeopleAssignment', foreign_key: :responsibility_id
  has_many :role_rules, class_name: 'GkPeopleRoleRule', foreign_key: :responsibility_id
  belongs_to :wiki_page, class_name: 'WikiPage', optional: true

  validates :key, presence: true, uniqueness: true, format: { with: GkPeople::KEY_FORMAT }
  validates :name, presence: true, length: { maximum: 200 }
  validates :kind, inclusion: { in: GkPeople::Responsibilities::KINDS }

  before_validation { self.name = name.to_s.strip }
  after_create_commit { GkPeople.write_on(self, 'responsibility_created', { key: key, name: name, kind: kind }) }
  after_update_commit :changed_event

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(:position, Arel.sql('lower(gk_people_responsibilities.name)')) }

  def to_s = name.to_s
  def single_holder? = kind != 'area'

  private

  def changed_event
    ch = saved_changes.except('updated_at', 'created_at')
    GkPeople.write_on(self, 'responsibility_changed', ch.transform_values(&:last)) if ch.any?
  end
end
