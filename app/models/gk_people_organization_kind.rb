# frozen_string_literal: true

# An organization's relation to us: a kind (customer, supplier, studied, collaborator...), in one project or global,
# from and to a date, with a reason. A relation that ends keeps its row with valid_to; nothing is deleted once it has
# been in force. The history is also in records (organization_relation_added, organization_relation_ended).
class GkPeopleOrganizationKind < ApplicationRecord
  self.table_name = 'gk_people_organization_kinds'

  belongs_to :organization, class_name: 'GkPeopleOrganization'
  belongs_to :kind, class_name: 'GkPeopleOrgKind'
  belongs_to :project, optional: true
  belongs_to :created_by, class_name: 'User', optional: true

  validates :reason, length: { maximum: 2000 }
  validate :dates_in_order

  before_save { self.updated_at = Time.current }

  # In force on a day (today unless said): begun (or no start) and not ended
  scope :current, ->(on = User.current.today) { where('(gk_people_organization_kinds.valid_from IS NULL OR gk_people_organization_kinds.valid_from <= ?) AND (gk_people_organization_kinds.valid_to IS NULL OR gk_people_organization_kinds.valid_to >= ?)', on, on) }
  scope :global, -> { where(project_id: nil) }
  # A relation in a project is seen only by those who may see the project (a studied company never shows where it
  # does not belong); global ones by everyone who sees the registers
  scope :visible, ->(user = User.current) { where(project_id: nil).or(where(project_id: Project.visible(user).select(:id))) }
  scope :sorted, -> { order(Arel.sql('gk_people_organization_kinds.valid_to IS NOT NULL'), valid_from: :desc, id: :desc) }

  def state(on = User.current.today)
    return :future if valid_from && valid_from > on
    return :ended if valid_to && valid_to < on

    :current
  end

  def global? = project_id.nil?

  private

  def dates_in_order
    errors.add(:valid_to, :greater_than_or_equal_to, count: valid_from) if valid_from && valid_to && valid_to < valid_from
  end
end
