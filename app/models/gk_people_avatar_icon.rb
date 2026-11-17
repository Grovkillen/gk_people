# frozen_string_literal: true

# The icon chosen for an account (GkPeople::AvatarIcon): a name the icon library knows
class GkPeopleAvatarIcon < ApplicationRecord
  belongs_to :user, class_name: 'Principal'
  belongs_to :set_by, class_name: 'User', optional: true

  validates :icon, presence: true, length: { maximum: 120 }
  validate { errors.add(:icon, :inclusion) unless GkPeople::AvatarIcon.known?(icon) }
end
