# frozen_string_literal: true

# The part of an account's picture-folder picture that is used (GkPeople::AvatarFolder): fractions of the picture
class GkPeopleAvatarRegion < ApplicationRecord
  belongs_to :user, class_name: 'Principal'
  belongs_to :set_by, class_name: 'User', optional: true

  validates :x, :y, numericality: { greater_than_or_equal_to: 0, less_than: 1 }
  validates :s, numericality: { greater_than: 0, less_than_or_equal_to: 1 }

  # What changes the pictures made from the file: the place, in a few characters
  def signature = format('%.4f,%.4f,%.4f', x, y, s)
end
