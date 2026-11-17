# frozen_string_literal: true

# A reserve account (GkPeople::Reserve): the account, whose it is (nil for the shared one), and its state.
class GkPeopleReserveAccount < ApplicationRecord
  self.table_name = 'gk_people_reserve_accounts'
  # instants with their zone: a reserve account stays unlocked until the instant, also in the hour
  # that comes twice
  GkPeopleInstant.attributes!(self, :unlocked_until, :last_synced_at)

  belongs_to :user
  belongs_to :owner, class_name: 'User', foreign_key: :owner_user_id, optional: true

  scope :active, -> { where(active: true) }

  def shared? = kind == 'shared'
  def open? = user&.status == ::Principal::STATUS_ACTIVE
end
