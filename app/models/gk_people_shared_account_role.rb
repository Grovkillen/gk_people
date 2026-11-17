# frozen_string_literal: true

# A row of a shared account's matrix: a people group or a single person gets a Redmine role in a project, at that
# computer (GkPeople::Actor). The account's own roles are the ceiling.
class GkPeopleSharedAccountRole < ApplicationRecord
  self.table_name = 'gk_people_shared_account_roles'

  belongs_to :user
  belongs_to :project
  belongs_to :role
  belongs_to :created_by, class_name: 'User', optional: true

  validates :principal_type, inclusion: { in: %w[group person] }
  before_validation { self.created_at ||= Time.current }

  def principal = (principal_type == 'group' ? GkPeopleGroup.find_by(id: principal_id) : GkPeoplePerson.find_by(id: principal_id))
end
