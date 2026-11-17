# frozen_string_literal: true

# A type of organization: data, never code, and an organization may have several ("Företag i kommunen" and
# "Samverkansaktör" at once). The key is set once (sync, import and REST name kinds by it); the name has other
# languages in gk_fields. A kind in use is switched off, never deleted.
class GkPeopleOrgKind < ApplicationRecord
  self.table_name = 'gk_people_org_kinds'

  has_many :links, class_name: 'GkPeopleOrganizationKind', foreign_key: :kind_id, dependent: :restrict_with_error

  validates :key, presence: true, uniqueness: true, format: { with: GkPeople::KEY_FORMAT }
  validates :name, presence: true, length: { maximum: 200 }

  before_validation { self.name = name.to_s.strip }

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(:position, Arel.sql('lower(gk_people_org_kinds.name)')) }

  def to_s = name.to_s
end
