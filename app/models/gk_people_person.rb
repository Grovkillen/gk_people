# frozen_string_literal: true

# A person, with or without an account (plugins/people, persons and accounts). The person is the truth and the
# account one of her identifiers: user_id, at most one account per person and one person per account. What the
# account owns (login, mail for signing in, language, status) stays on the account; the person owns name,
# organization, title, telephone and identifiers (or the source does, for synced persons).
class GkPeoplePerson < ApplicationRecord
  self.table_name = 'gk_people_persons'
  # instants with their zone
  GkPeopleInstant.attributes!(self, :synced_at, :external_deleted_at, :pin_set_at, :pin_locked_until)

  SOURCE_OWNS = %w[display_name first_name last_name organization_id email phone title active].freeze
  TRACKED = %w[display_name first_name last_name organization_id kind email phone title languages active info_source info_source_on].freeze

  # how and why the account was linked or unlinked in this save (written on the event, never stored here)
  attr_accessor :link_how, :link_reason
  # The line a quick contact came from and its reading, for the created event (never stored here);
  # created_event_written: the quick save wrote the created event itself, in its transaction, so the commit does not
  attr_accessor :quick_input, :created_event_written

  belongs_to :organization, class_name: 'GkPeopleOrganization', optional: true
  belongs_to :user, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :consents, -> { sorted }, class_name: 'GkPeopleConsent', foreign_key: :person_id
  has_many :identifiers, -> { order(:scheme_id, :id) }, class_name: 'GkPeopleIdentifier', foreign_key: :person_id, dependent: :destroy
  has_many :group_memberships, class_name: 'GkPeopleGroupMember', foreign_key: :person_id

  validates :kind, inclusion: { in: GkPeople::PERSON_KINDS }
  validates :user_id, uniqueness: true, allow_nil: true
  validates :info_source, length: { maximum: 200 }
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true
  validates :email, length: { maximum: 200 }, format: { with: /\A[^@\s]+@[^@\s]+\z/ }, allow_blank: true
  validate :has_a_name
  validate :account_is_a_user
  validate :internal_at_own_organization

  before_validation :tidy
  after_create_commit { GkPeople::PersonEvents.created(self) unless created_event_written }
  after_update_commit { GkPeople::PersonEvents.updated(self) }

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(Arel.sql("lower(coalesce(nullif(gk_people_persons.last_name, ''), gk_people_persons.display_name, ''))"), :first_name) }
  scope :with_account, -> { where.not(user_id: nil) }
  # One merged into another (records' link same_as from it) is left out of lists; quick_open are the quick contacts
  # still to complete
  scope :not_merged, -> { GkPeople::Quick.merged?(:person) ? where.not(id: GkPeople::Quick.merged_ids('person')) : all }
  scope :quick_open, -> { where(quick: true, active: true).not_merged }

  # Name, organization, e-mail, telephone, title, or the value of an identifier that is not a token
  def self.search(term)
    s = GkPeople::Sql
    a = arel_table
    ids = GkPeopleIdentifier.joins(:scheme).where.not(gk_people_schemes: { kind: 'token' }).where(s.like(GkPeopleIdentifier.arel_table[:value], term)).select(:person_id)
    orgs = GkPeopleOrganization.where(s.like(GkPeopleOrganization.arel_table[:name], term)).select(:id)
    where(s.like(s.full_name(a), term).or(s.like(a[:email], term)).or(s.like(a[:phone], term)).or(s.like(a[:title], term)))
      .or(where(id: ids)).or(where(organization_id: orgs))
  end

  def name = GkPeople::Name.of(display_name, first_name, last_name)
  def to_s = name
  def synced? = source.present?
  def owned_by_source?(attr) = synced? && SOURCE_OWNS.include?(attr.to_s)

  def language_list = languages.to_s.split(/[\s,]+/).reject(&:empty?)

  # The identifiers in force, the preferred first within each scheme
  def identifiers_in_force = identifiers.includes(:scheme).select(&:in_force?).sort_by { |i| [i.scheme.position, i.preferred ? 0 : 1, i.id] }

  private

  def tidy
    %w[display_name first_name last_name email phone title].each { |a| self[a] = self[a].to_s.strip.presence }
    self.languages = language_list.map(&:downcase).uniq.join(', ').presence
  end

  def has_a_name
    errors.add(:base, ::I18n.t(:error_gk_people_no_name)) if name.blank?
  end

  def account_is_a_user
    errors.add(:user_id, :invalid) if user_id && !::User.where(type: 'User').exists?(id: user_id)
  end

  # One of our own people is tied only to an organization with the relation internal (our own), once the instance
  # has one; checked when the organization is set or changed, so older rows stand
  def internal_at_own_organization
    return unless kind == 'internal' && organization_id && will_save_change_to_organization_id?
    return unless GkPeopleOrganizationKind.current.joins(:kind).where(gk_people_org_kinds: { key: 'internal' }).exists?
    return if organization&.relation?('internal')

    errors.add(:base, I18n.t(:error_gk_people_internal_org))
  end
end
