# frozen_string_literal: true

# A rule on a responsibility (GkPeople::RoleSync): which Redmine role the holder gets, and where: the assignment's
# own project (scope), a named project, or every project of a project type (gk_project_types).
class GkPeopleRoleRule < ApplicationRecord
  self.table_name = 'gk_people_role_rules'

  TARGETS = %w[scope project project_type].freeze

  belongs_to :responsibility, class_name: 'GkPeopleResponsibility'
  belongs_to :role
  belongs_to :project, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :target, inclusion: { in: TARGETS }
  validate :target_given
  validate :role_givable

  before_validation { self.created_at ||= Time.current }

  def project_type = (defined?(::GkProjectTypesType) && project_type_id ? ::GkProjectTypesType.find_by(id: project_type_id) : nil)

  def target_label
    case target
    when 'scope' then I18n.t(:label_gk_people_rule_scope)
    when 'project' then project&.name.to_s
    when 'project_type' then I18n.t(:label_gk_people_rule_project_type, name: project_type&.name.to_s)
    end
  end

  private

  def target_given
    errors.add(:project_id, :blank) if target == 'project' && project.nil?
    errors.add(:base, I18n.t(:error_gk_people_rule_project_type)) if target == 'project_type' && project_type.nil?
  end

  def role_givable
    errors.add(:role_id, :invalid) if role && (role.builtin? || !role.member?)
  end
end
