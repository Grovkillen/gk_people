# frozen_string_literal: true

# A role people gave because of a responsibility (GkPeople::RoleSync): who, in which project, which role, through
# which rule and assignment, as holder or deputy. member_role_id is the membership role people made; nil when the
# role was already there (then people neither made nor removes it). Never removed: revoked with a reason.
class GkPeopleRoleGrant < ApplicationRecord
  self.table_name = 'gk_people_role_grants'
  # instants with their zone
  GkPeopleInstant.attributes!(self, :granted_at, :revoked_at, :removed_by_hand_at)

  belongs_to :rule, class_name: 'GkPeopleRoleRule', optional: true
  belongs_to :assignment, class_name: 'GkPeopleAssignment', optional: true
  belongs_to :person, class_name: 'GkPeoplePerson', optional: true
  belongs_to :user, optional: true
  belongs_to :project, optional: true
  belongs_to :role, optional: true
  belongs_to :removed_by, class_name: 'User', optional: true

  scope :active, -> { where(revoked_at: nil) }
  scope :deviating, -> { active.where.not(removed_by_hand_at: nil) }

  def key = [rule_id, assignment_id, via, user_id, project_id, role_id]
  def upr = [user_id, project_id, role_id]
  def covered? = member_role_id.nil? && removed_by_hand_at.nil?
  def deviating? = removed_by_hand_at.present?
end
