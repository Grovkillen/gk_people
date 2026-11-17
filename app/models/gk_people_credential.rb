# frozen_string_literal: true

# A credential held by a person or an organization (GkPeople::Credentials): its kind by key, issued, valid until,
# the issuer and the number, the proof as attachments. Never removed: revoked with a reason. Who sees it is the
# credential's own question (attachments too): one in force is seen by anyone who sees the registers; an expired or
# revoked credential of a person only by herself and those who handle credentials or responsibilities.
class GkPeopleCredential < ApplicationRecord
  self.table_name = 'gk_people_credentials'
  # an instant with its zone
  GkPeopleInstant.attributes!(self, :revoked_at)

  belongs_to :person, class_name: 'GkPeoplePerson', optional: true
  belongs_to :organization, class_name: 'GkPeopleOrganization', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :revoked_by, class_name: 'User', optional: true

  acts_as_attachable view_permission: :gk_people_view, edit_permission: :gk_people_manage_credentials,
                     delete_permission: :gk_people_manage_credentials

  validates :credential_key, presence: true
  validate :one_holder
  validate :kind_fits
  validate :dates_in_order
  validates :issuer, length: { maximum: 200 }
  validates :reference, length: { maximum: 100 }

  before_validation :valid_to_from_kind, on: :create

  scope :not_revoked, -> { where(revoked_at: nil) }
  # No last day first, then the latest (the order NULLS FIRST gave, on any database)
  scope :sorted, -> { order(Arel.sql('gk_people_credentials.valid_to IS NULL DESC'), valid_to: :desc, id: :desc) }
  # In force on a day: not revoked, issued (or no date) and not past its last day
  scope :in_force, lambda { |on = User.current.today|
    not_revoked.where('gk_people_credentials.issued_on IS NULL OR gk_people_credentials.issued_on <= ?', on)
               .where('gk_people_credentials.valid_to IS NULL OR gk_people_credentials.valid_to >= ?', on)
  }

  def kind = @kind ||= GkPeopleCredentialKind.find_by(key: credential_key)
  def holder = person || organization
  def holder_type = person_id ? 'person' : 'organization'
  def project = nil
  def to_s = kind&.name || credential_key

  # valid, expiring (in force, its last day within the warning days), not_yet, expired, revoked
  def status(on = User.current.today)
    return :revoked if revoked_at
    return :not_yet if issued_on && issued_on > on
    return :expired if valid_to && valid_to < on
    return :expiring if valid_to && valid_to <= on + GkPeople::Credentials.warn_days

    :valid
  end

  def in_force?(on = User.current.today) = %i[valid expiring].include?(status(on))

  def visible?(user = User.current) = GkPeople::Credentials.visible?(self, user)
  def attachments_visible?(user = User.current) = visible?(user)
  def attachments_editable?(user = User.current) = visible?(user) && GkPeople::Credentials.manage?(user)
  def attachments_deletable?(user = User.current) = attachments_editable?(user)

  private

  def one_holder
    errors.add(:base, I18n.t(:error_gk_people_credential_holder)) unless person_id.present? ^ organization_id.present?
  end

  def kind_fits
    k = kind
    if k.nil?
      errors.add(:credential_key, :invalid)
    elsif !k.for?(holder_type)
      errors.add(:base, I18n.t(:error_gk_people_credential_kind_holder, name: k.name))
    end
  end

  def dates_in_order
    errors.add(:valid_to, :invalid) if issued_on && valid_to && valid_to < issued_on
  end

  # Valid for the kind's months from the issue, when no end is given
  def valid_to_from_kind
    self.valid_to ||= issued_on >> kind.renew_months if issued_on && kind&.renew_months
  end
end
