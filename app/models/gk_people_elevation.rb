# frozen_string_literal: true

# One time an administrator stepped up (GkPeople::Elevation). Open while ended_at is empty and expires_at is ahead.
class GkPeopleElevation < ApplicationRecord
  self.table_name = 'gk_people_elevations'
  self.inheritance_column = nil
  # instants with their zone: an elevation ends at its instant, also in the hour that comes twice
  GkPeopleInstant.attributes!(self, :started_at, :expires_at, :last_activity_at, :ended_at)

  belongs_to :user
  belongs_to :person, class_name: 'GkPeoplePerson', optional: true
  has_many :actions, -> { order(:at, :id) }, class_name: 'GkPeopleElevationAction', foreign_key: :elevation_id

  # through the attribute (arel), so now goes to the database with its offset (expires_at has its zone)
  scope :open, -> { where(ended_at: nil).where(arel_table[:expires_at].gt(Time.current)) }
  scope :sorted, -> { order(started_at: :desc) }

  def open? = ended_at.nil? && expires_at > Time.current

  # Ends it once; an elapsed one ends at the time it ran out, not at the time someone noticed
  def end!(reason)
    return self if ended_at

    at = reason == 'expired' ? [expires_at, Time.current].min : Time.current
    update_columns(ended_at: at, end_reason: reason)
    GkPeople.write(user, 'elevation_ended', { elevation_id: id, how: reason, actions: actions.count })
    self
  end
end
