# frozen_string_literal: true

# One run of role_sync (daily, at a change, by hand or in a scenario) and what it did
class GkPeopleRoleSyncRun < ApplicationRecord
  self.table_name = 'gk_people_role_sync_runs'

  belongs_to :user, optional: true

  scope :sorted, -> { order(started_at: :desc, id: :desc) }
end
