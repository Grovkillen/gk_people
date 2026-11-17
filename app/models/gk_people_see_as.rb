# frozen_string_literal: true

# One time an administrator looked at the pages as someone else (GkPeople::SeeAs). Open while ended_at is empty and
# its elevation is open.
class GkPeopleSeeAs < ApplicationRecord
  self.table_name = 'gk_people_see_as_sessions'
  # instants with their zone
  GkPeopleInstant.attributes!(self, :started_at, :ended_at)
  self.inheritance_column = nil

  KINDS = %w[person group role].freeze

  belongs_to :elevation, class_name: 'GkPeopleElevation'
  belongs_to :user
  belongs_to :person, class_name: 'GkPeoplePerson', optional: true
  belongs_to :target_user, class_name: 'User', optional: true
  belongs_to :target_group, class_name: 'Group', optional: true
  belongs_to :role, optional: true
  belongs_to :project, optional: true

  validates :kind, inclusion: { in: KINDS }

  scope :sorted, -> { order(started_at: :desc) }

  def open? = ended_at.nil? && elevation&.open?

  # Whom or what, for lists, the top menu line and the ribbon:
  # "Saga Forsmyr", "gruppen Kvalitet", "rollen Rapportör i Kundsupport"
  def target_label
    case kind
    when 'person' then target_user&.name.to_s
    when 'group' then I18n.t(:label_gk_people_see_as_group_named, name: target_group&.lastname.to_s)
    else I18n.t(:label_gk_people_see_as_role_named, name: role&.name.to_s, project: project&.name.to_s)
    end
  end

  # The ribbon's short word: a person's first name, a group's name, a role's name
  def ribbon_word
    case kind
    when 'person' then target_user&.firstname.presence || target_label
    when 'group' then target_group&.lastname.to_s
    else role&.name.to_s
    end
  end

  # Whom, for the ribbon's whole sentence, the top menu line and the phone row: a person's full name, with the login
  # when another active user has the same first and last name, so that the two can be told apart. The name is whole
  # also when the instance's user format shortens it
  def ribbon_who
    u = target_user
    return target_label unless kind == 'person' && u

    full = SHORT_USER_FORMATS.include?(Setting.user_format.to_s) ? u.name(:firstname_lastname) : u.name
    twin = User.active.where(firstname: u.firstname, lastname: u.lastname).where.not(id: u.id).exists?
    twin ? I18n.t(:label_gk_people_see_as_twin, name: full, login: u.login) : full
  end

  SHORT_USER_FORMATS = %w[firstname firstname_lastinitial firstinitial_lastname lastname username].freeze

  def end!(reason)
    return self if ended_at

    update_columns(ended_at: Time.current, end_reason: reason)
    GkPeople.write(user, 'see_as_ended', { see_as_id: id, how: reason, pages: pages })
    self
  end
end
