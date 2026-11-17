# frozen_string_literal: true

# An organization: a customer, a supplier, an authority, a partner, or a part of one's own (plugins/people,
# organizations). A person belongs to none or one. Synced ones (source set) have the fields the source owns locked
# here; the approval columns are set by hand until the supplier assessment sets them.
# kind_keys are the global relations in force today, as before; a key taken away ends its relation (valid_to
# yesterday) instead of deleting it. What a reader is shown are the relations in force she may see (visible_kinds);
# one in a project only to those who may see the project. info_source is the import's source ("hämtat ur fil X den
# dagen"), never a source in the study's sense, which belongs in the source register.
class GkPeopleOrganization < ApplicationRecord
  self.table_name = 'gk_people_organizations'
  # instants with their zone
  GkPeopleInstant.attributes!(self, :approved_at, :synced_at, :external_deleted_at)

  SOURCE_OWNS = %w[name kind_keys org_no address country active].freeze

  has_many :persons, -> { order(:last_name, :first_name, :display_name) }, class_name: 'GkPeoplePerson', foreign_key: :organization_id
  has_many :kind_links, class_name: 'GkPeopleOrganizationKind', foreign_key: :organization_id, dependent: :delete_all
  has_many :current_global_links, -> { current.global }, class_name: 'GkPeopleOrganizationKind', foreign_key: :organization_id
  has_many :kinds, -> { sorted }, through: :current_global_links, source: :kind
  belongs_to :approved_by, class_name: 'User', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  # A company and its workplaces, a group and its companies. An organization is never its own ancestor (no_cycle).
  belongs_to :parent, class_name: 'GkPeopleOrganization', optional: true
  has_many :children, -> { order(:name) }, class_name: 'GkPeopleOrganization', foreign_key: :parent_id

  validates :name, presence: true, length: { maximum: 200 }
  validates :approval_status, inclusion: { in: GkPeople::APPROVAL }
  validates :country, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true
  validates :info_source, length: { maximum: 200 }
  validates :city, length: { maximum: 100 }
  validates :short_name, length: { maximum: 40 }
  validates :phone, length: { maximum: 60 }
  validates :website, length: { maximum: 255 }
  validates :email, length: { maximum: 200 }, format: { with: /\A[^@\s]+@[^@\s]+\z/ }, allow_blank: true
  validates :owner_langs, format: { with: /\A(\*|[a-z]{2}(-[A-Za-z]{2})?)(,(\*|[a-z]{2}(-[A-Za-z]{2})?))*\z/ }, allow_blank: true
  validates :sni, format: { with: /\A[0-9A-Z.]{1,20}\z/ }, allow_blank: true
  validate :known_kinds
  # SWEREF 99 TM by default, read by gis when it is built
  validates :location_n, :location_e, numericality: true, allow_nil: true
  validates :location_crs, length: { maximum: 20 }
  validates :org_form, length: { maximum: 100 }
  validates :size_class, length: { maximum: 60 }
  validate :no_cycle
  # The picture folder: a folder when it is on, and a rule people knows
  validates :avatar_folder, length: { maximum: 500 }
  validates :avatar_folder, presence: true, if: :avatar_folder_on
  validate { errors.add(:avatar_name_rule, :inclusion) unless GkPeople::AvatarFolder.valid_rule?(avatar_name_rule) }
  # A folder switched off, moved or renamed: its pictures go now, not at night
  after_update_commit do
    if saved_change_to_avatar_folder_on? || saved_change_to_avatar_folder? || saved_change_to_avatar_name_rule?
      GkPeople::AvatarFolder.sweep!
    end
  end

  # The number's digits, for a search by number on any database
  before_save { self.org_no_digits = org_no.to_s.gsub(/\D/, '').presence if has_attribute?(:org_no_digits) }
  scope :by_number, ->(digits) { where(org_no_digits: digits.to_s.gsub(/\D/, '')) }

  before_validation do
    self.country = country.to_s.strip.upcase.presence
    self.sni = sni.to_s.strip.upcase.presence
    self.city = city.to_s.strip.presence
  end
  before_save :approval_stamp
  before_save { self.updated_at = Time.current if kinds_differ? && persisted? }
  after_save :apply_kind_keys
  after_create_commit { GkPeople::OrgEvents.created(self) unless created_event_written }
  after_update_commit { GkPeople::OrgEvents.updated(self) }

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(:name) }
  # As on persons, one merged into another is left out of lists; quick_open still to complete
  scope :not_merged, -> { GkPeople::Quick.merged?(:organization) ? where.not(id: GkPeople::Quick.merged_ids('organization')) : all }
  scope :quick_open, -> { where(quick: true, active: true).not_merged }
  # a relation of the kind in force today that the reader may see (global, or in a project she sees); with project:
  # only global ones and those in that project (a picker in a project)
  scope :with_kind, lambda { |key, project: nil, user: User.current|
    rel = GkPeopleOrganizationKind.current.visible(user).joins(:kind).where(gk_people_org_kinds: { key: key.to_s })
    rel = rel.where(project_id: [nil, project.id]) if project
    where(id: rel.select(:organization_id))
  }

  # [before, after] of the kinds when the last save changed them (for the event)
  attr_reader :kinds_change
  # As on persons (GkPeoplePerson#quick_input)
  attr_accessor :quick_input, :created_event_written

  def self.search(term)
    a = arel_table
    where(GkPeople::Sql.like(a[:name], term).or(GkPeople::Sql.like(a[:org_no], term)))
  end

  def to_s = name.to_s
  def synced? = source.present?

  # What the reader may change here: everything, unless the source owns it
  def owned_by_source?(attr) = synced? && SOURCE_OWNS.include?(attr.to_s)

  def kind_keys
    return @kind_keys_to_set.dup if @kind_keys_to_set

    persisted? ? kinds.map(&:key) : []
  end

  def kind_keys=(keys)
    @kind_keys_to_set = Array(keys).flat_map { |k| k.to_s.split(/[;,|]/) }.map(&:strip).reject(&:empty?).uniq
  end

  def kind_names = kinds.map(&:name)

  # The relations a reader may see, the ones in force first; and the kinds in force among them
  def visible_relations(user = User.current) = kind_links.visible(user).includes(:kind, :project).sorted.to_a
  def visible_kinds(user = User.current) = kind_links.current.visible(user).includes(:kind).map(&:kind).uniq.sort_by { |k| [k.position, k.name.downcase] }
  def relation?(key, on: User.current.today) = kind_links.current(on).joins(:kind).where(gk_people_org_kinds: { key: key.to_s }).exists?

  # Kinds set that differ from those stored (a save with only this is still a change)
  def kinds_pending? = !@kind_keys_to_set.nil? && @kind_keys_to_set.sort != stored_kind_keys.sort

  # Every organization below this one, at any depth (ids)
  def descendant_ids
    return [] unless id

    out = []
    level = [id]
    until level.empty?
      level = GkPeopleOrganization.where(parent_id: level).where.not(id: out + [id]).pluck(:id)
      out.concat(level)
    end
    out
  end

  # The line up to the top: parent, its parent and so on (stops at a cycle in old data)
  def ancestors
    out = []
    at = parent
    while at && out.none? { |o| o.id == at.id } && at.id != id
      out << at
      at = at.parent
    end
    out
  end

  def location? = !location_n.nil? && !location_e.nil?

  private

  # An organization cannot be its own ancestor: the parent chosen may not be itself or one of its descendants
  def no_cycle
    return unless parent_id

    if persisted? && (parent_id == id || descendant_ids.include?(parent_id))
      errors.add(:base, I18n.t(:error_gk_people_org_parent_cycle))
    elsif !GkPeopleOrganization.exists?(id: parent_id)
      errors.add(:base, I18n.t(:error_gk_people_org_parent_missing))
    end
  end

  def stored_kind_keys = persisted? ? GkPeopleOrganizationKind.current.global.joins(:kind).where(organization_id: id).pluck('gk_people_org_kinds.key').uniq : []

  def kinds_differ? = kinds_pending?

  def known_kinds
    return unless @kind_keys_to_set

    unknown = @kind_keys_to_set - GkPeopleOrgKind.where(key: @kind_keys_to_set).pluck(:key)
    errors.add(:base, I18n.t(:error_gk_people_unknown_org_kind, keys: unknown.join(', '))) if unknown.any?
  end

  def apply_kind_keys
    @kinds_change = nil
    return unless @kind_keys_to_set

    before = stored_kind_keys
    after = @kind_keys_to_set
    @kind_keys_to_set = nil
    return if before.sort == after.sort

    ids = GkPeopleOrgKind.where(key: after).pluck(:key, :id).to_h
    gone = GkPeopleOrgKind.where(key: before - after).pluck(:id)
    today = User.current.today
    # a relation taken away ends yesterday; one that began today never was in force and goes
    GkPeopleOrganizationKind.current.global.where(organization_id: id, kind_id: gone).find_each do |r|
      r.valid_from && r.valid_from >= today ? r.delete : r.update_columns(valid_to: today - 1, updated_at: Time.current)
    end
    (after - before).each do |k|
      GkPeopleOrganizationKind.create!(organization_id: id, kind_id: ids[k], valid_from: today, created_at: Time.current,
                                     created_by_id: User.current.logged? ? User.current.id : nil)
    end
    kinds.reset
    current_global_links.reset
    @kinds_change = [before.sort, after.sort]
  end

  # Who set the approval and when follow the status: set when it changes, never typed
  def approval_stamp
    return unless will_save_change_to_approval_status?

    if approval_status == 'not_assessed'
      self.approved_by_id = nil
      self.approved_at = nil
    else
      self.approved_by_id = User.current.logged? ? User.current.id : nil
      self.approved_at = Time.current
    end
  end
end
