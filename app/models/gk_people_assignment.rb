# frozen_string_literal: true

# A person holding a responsibility in a scope, from and until a day, with a deputy (GkPeople::Responsibilities).
# Never removed: ending is a date. One holder per scope at a time for a function; several for an area.
class GkPeopleAssignment < ApplicationRecord
  self.table_name = 'gk_people_assignments'
  # an instant with its zone
  GkPeopleInstant.attributes!(self, :ended_at)

  belongs_to :responsibility, class_name: 'GkPeopleResponsibility'
  belongs_to :person, class_name: 'GkPeoplePerson'
  belongs_to :deputy, class_name: 'GkPeoplePerson', foreign_key: :deputy_person_id, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :ended_by, class_name: 'User', optional: true

  validates :scope_type, inclusion: { in: GkPeople::Responsibilities::SCOPES }
  validate :scope_exists
  validate :dates_in_order
  validate :one_holder_for_a_function
  validate :deputy_is_someone_else

  before_validation { self.created_at ||= Time.current }

  # In force on a day: begun (or no start) and not ended before it
  scope :in_force, lambda { |on = User.current.today|
    where('gk_people_assignments.valid_from IS NULL OR gk_people_assignments.valid_from <= ?', on)
      .where('gk_people_assignments.valid_to IS NULL OR gk_people_assignments.valid_to >= ?', on)
  }
  # The latest start first, no start last (the order NULLS LAST gave, on any database)
  scope :sorted, -> { order(Arel.sql('gk_people_assignments.valid_from IS NULL'), valid_from: :desc, id: :desc) }

  def in_force?(on = User.current.today) = (valid_from.nil? || valid_from <= on) && (valid_to.nil? || valid_to >= on)
  def ended? = valid_to.present? && valid_to < User.current.today

  # The deputy stands in during her own period even if the holder is there
  def deputy_period_covers?(on)
    deputy_person_id.present? && (deputy_valid_from.present? || deputy_valid_to.present?) &&
      (deputy_valid_from.nil? || deputy_valid_from <= on) && (deputy_valid_to.nil? || deputy_valid_to >= on)
  end

  def scope_record
    case scope_type
    when 'project' then Project.find_by(id: scope_id)
    when 'group' then GkPeopleGroup.find_by(id: scope_id)
    end
  end

  def scope_label
    scope_type == 'organization' ? I18n.t(:label_gk_people_scope_organization) : scope_record&.to_s.presence || "##{scope_id}"
  end

  private

  def scope_exists
    return if scope_type == 'organization' && scope_id.nil?

    errors.add(:base, I18n.t(:error_gk_people_scope_missing)) if scope_record.nil?
  end

  def dates_in_order
    errors.add(:valid_to, :invalid) if valid_from && valid_to && valid_to < valid_from && ended_at.nil?
    errors.add(:deputy_valid_to, :invalid) if deputy_valid_from && deputy_valid_to && deputy_valid_to < deputy_valid_from
  end

  # A function has one holder per scope at a time: the periods may not overlap
  def one_holder_for_a_function
    return unless responsibility&.single_holder? && ended_at.nil?

    others = GkPeopleAssignment.where(responsibility_id: responsibility_id, scope_type: scope_type, scope_id: scope_id).where.not(id: id)
    from = valid_from || Date.new(1900, 1, 1)
    to = valid_to || Date.new(9999, 12, 31)
    clash = others.where('gk_people_assignments.valid_from IS NULL OR gk_people_assignments.valid_from <= ?', to)
                  .where('gk_people_assignments.valid_to IS NULL OR gk_people_assignments.valid_to >= ?', from)
    errors.add(:base, I18n.t(:error_gk_people_one_holder, name: responsibility.name)) if clash.exists?
  end

  def deputy_is_someone_else
    return if deputy_person_id.blank?

    errors.add(:deputy_person_id, :invalid) if deputy_person_id == person_id
    # a deputy that is set or changed must be a person that exists (rows from before are left as they are)
    errors.add(:deputy_person_id, :invalid) if deputy_person_id_changed? && !GkPeoplePerson.exists?(id: deputy_person_id)
  end
end
