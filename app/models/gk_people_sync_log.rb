# frozen_string_literal: true

# One call to a sync endpoint (GkPeople::Sync): source, register, who, when, the counts and the errors per post.
class GkPeopleSyncLog < ApplicationRecord
  self.table_name = 'gk_people_sync_log'
  # instants with their zone
  GkPeopleInstant.attributes!(self, :started_at, :finished_at)

  belongs_to :user, optional: true

  scope :sorted, -> { order(started_at: :desc, id: :desc) }

  def errors_list = (JSON.parse(errors_json.to_s) rescue [])
end
