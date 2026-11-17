# frozen_string_literal: true

# A kind of credential (GkPeople::Credentials): data, never code. Who may hold it (persons, organizations or both)
# and how long one is valid from its issue when nothing else is given. The key is set once (credentials and the
# requirements of responsibilities refer to it); the name has other languages in gk_fields.
class GkPeopleCredentialKind < ApplicationRecord
  self.table_name = 'gk_people_credential_kinds'

  APPLIES_TO = %w[person organization both].freeze

  validates :key, presence: true, uniqueness: true, format: { with: GkPeople::KEY_FORMAT }
  validates :name, presence: true, length: { maximum: 200 }
  validates :applies_to, inclusion: { in: APPLIES_TO }
  validates :renew_months, numericality: { only_integer: true, greater_than: 0, less_than: 1200 }, allow_nil: true

  before_validation { self.name = name.to_s.strip }

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(:position, Arel.sql('lower(gk_people_credential_kinds.name)')) }
  scope :for_holder, ->(type) { where(applies_to: [type.to_s, 'both']) }

  def to_s = name.to_s
  def for?(type) = applies_to == 'both' || applies_to == type.to_s
end
