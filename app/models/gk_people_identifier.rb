# frozen_string_literal: true

# One identifier of a person under a scheme. A token's value is never kept in clear text: value holds the masked
# form and value_digest what lookup compares (GkPeople::Identify). Unique per scheme when the scheme says so.
class GkPeopleIdentifier < ApplicationRecord
  self.table_name = 'gk_people_identifiers'

  belongs_to :person, class_name: 'GkPeoplePerson'
  belongs_to :scheme, class_name: 'GkPeopleScheme'

  attr_reader :raw_value

  validates :value, presence: true, length: { maximum: 300 }
  validate :value_fits_scheme
  validate :value_unique_in_scheme

  scope :active, -> { where(active: true) }
  scope :in_force, ->(day = User.current.today) { active.where('valid_from IS NULL OR valid_from <= ?', day).where('valid_to IS NULL OR valid_to >= ?', day) }

  # The value as typed or read: a token is kept as digest and mask, everything else as it is
  def raw_value=(v)
    @raw_value = v.to_s.strip
    if scheme&.token?
      self.value = GkPeople::Token.mask(@raw_value)
      self.value_digest = @raw_value.empty? ? nil : GkPeople::Token.digest(@raw_value)
    else
      self.value = @raw_value
      self.value_digest = nil
    end
  end

  def in_force?(day = User.current.today) = active && (valid_from.nil? || valid_from <= day) && (valid_to.nil? || valid_to >= day)

  # The channel link for this identifier on a page (contact schemes with a link template), or nil
  def link(context = {})
    return nil unless scheme&.contact? && in_force?

    GkPeople::Channel.link(scheme.link_template, value, context)
  end

  private

  def value_fits_scheme
    return if scheme.nil? || @raw_value.nil? # an untouched token is not checked again (its clear value is gone)

    errors.add(:value, :invalid) unless GkPeople.format_ok?(scheme.format, @raw_value)
    # a token at least so long (the setting token_min_length), so its digest cannot simply be counted back; values
    # kept before are left as they are
    return unless scheme.token? && !@raw_value.empty?

    min = GkPeople::Token.min_length(((Setting.plugin_gk_people rescue {}) || {})['token_min_length'])
    errors.add(:value, :too_short, count: min) unless GkPeople::Token.long_enough?(@raw_value, min)
  end

  def value_unique_in_scheme
    return unless scheme&.unique_value

    others = self.class.where(scheme_id: scheme_id).where.not(id: id).active
    taken = scheme.token? ? others.where(value_digest: value_digest).exists? : others.where('lower(value) = lower(?)', value.to_s).exists?
    errors.add(:value, :taken) if taken
  end
end
