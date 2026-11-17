# frozen_string_literal: true

# One thing done on a shared account (GkPeople::Actor): what (action), on which issue, journal or time entry, by
# which person, through which account. details keeps what is needed when the thing is gone. Shown as "Registrerad av
# <person> via <konto>"; Redmine's author is not touched.
class GkPeopleActorRecord < ApplicationRecord
  self.table_name = 'gk_people_actor_records'
  # captured_at is an instant with its zone, so the order holds in the hour that comes twice
  GkPeopleInstant.attributes!(self, :captured_at)

  belongs_to :issue, optional: true
  belongs_to :journal, optional: true
  belongs_to :time_entry, optional: true
  belongs_to :project, optional: true
  belongs_to :person, class_name: 'GkPeoplePerson'
  belongs_to :user
  belongs_to :scheme, class_name: 'GkPeopleScheme', optional: true

  validates :captured_by, inclusion: { in: GkPeople::Actor::CAPTURED }
  validates :action, inclusion: { in: GkPeople::Actor::ACTIONS }

  scope :sorted, -> { order(captured_at: :desc, id: :desc) }
  # On issues the user may see; time without an issue where she may see time; what is gone (a deleted issue) only
  # for an administrator
  scope :visible, lambda { |user = User.current|
    next all if user.admin?

    issues = Issue.visible(user).select(:id)
    time = Project.where(Project.allowed_to_condition(user, :view_time_entries)).select(:id)
    where(issue_id: issues).or(where(issue_id: nil, project_id: time).where.not(action: 'deleted'))
  }

  def details_hash = (JSON.parse(details.to_s) rescue {})
end
