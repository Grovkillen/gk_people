# frozen_string_literal: true

# One size of an account's own picture (GkPeople::Avatars): a JPEG made on the server, never the original
class GkPeopleAvatar < ApplicationRecord
  belongs_to :user, class_name: 'Principal'
  belongs_to :set_by, class_name: 'User', optional: true

  validates :size, inclusion: { in: ->(_) { GkPeople::Avatars::SIZES } }
  validates :data, :checksum, presence: true
end
