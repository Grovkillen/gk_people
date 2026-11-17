# frozen_string_literal: true

# A person's consent: for a purpose (a deep interview in a project, say), given on a day, valid to a day or until
# revoked. Revoking keeps the row with the day and the reason; nothing is deleted. The register is declared in the
# record of processing (category consent) and its rows are in the person's extract. Events in records:
# person_consent_given, person_consent_revoked.
class GkPeopleConsent < ApplicationRecord
  self.table_name = 'gk_people_consents'

  belongs_to :person, class_name: 'GkPeoplePerson'
  belongs_to :project, optional: true
  belongs_to :recorded_by, class_name: 'User', optional: true
  belongs_to :revoked_by, class_name: 'User', optional: true

  validates :purpose, presence: true, length: { maximum: 200 }
  validates :given_on, presence: true
  validates :revoke_reason, length: { maximum: 2000 }
  validate :dates_in_order

  scope :sorted, -> { order(given_on: :desc, id: :desc) }

  def state(on = User.current.today)
    return :revoked if revoked_on && revoked_on <= on
    return :future if given_on > on
    return :expired if valid_to && valid_to < on

    :current
  end

  def current?(on = User.current.today) = state(on) == :current

  private

  def dates_in_order
    errors.add(:valid_to, :greater_than_or_equal_to, count: given_on) if given_on && valid_to && valid_to < given_on
    errors.add(:revoked_on, :greater_than_or_equal_to, count: given_on) if given_on && revoked_on && revoked_on < given_on
  end
end
