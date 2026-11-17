# frozen_string_literal: true

# An identifier scheme (plugins/people, identifiers): what sort of identifier a person can have. Data, not code:
# e-mail, telephone, Teams, employee number and a reader's token are all rows here. contact reaches the person (and
# may have a link template: a channel), reference matches her at a sync, token identifies her at an input device.
# The name has other languages in gk_fields (translations, one place).
class GkPeopleScheme < ApplicationRecord
  self.table_name = 'gk_people_schemes'

  has_many :identifiers, class_name: 'GkPeopleIdentifier', foreign_key: :scheme_id

  validates :key, presence: true, uniqueness: true, format: { with: GkPeople::KEY_FORMAT }
  validates :name, presence: true, length: { maximum: 120 }
  validates :kind, inclusion: { in: GkPeople::SCHEME_KINDS }
  validate :format_compiles
  validate :link_is_a_link

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(:position, :name) }

  def token? = kind == 'token'
  def contact? = kind == 'contact'

  def show_on_list
    JSON.parse(show_on.presence || '[]')
  rescue JSON::ParserError
    []
  end

  def show_on_list=(list)
    self.show_on = (Array(list).map(&:to_s) & GkPeople::SHOW_ON).to_json
  end

  def shown_on?(place) = show_on_list.include?(place.to_s)
  def to_s = name.to_s

  private

  def format_compiles
    Regexp.new(format.to_s) if format.present?
  rescue RegexpError => e
    errors.add(:format, e.message)
  end

  def link_is_a_link
    return if link_template.blank?

    errors.add(:link_template, :invalid) unless contact? && GkPeople::Channel.link(link_template, 'x')
  end
end
