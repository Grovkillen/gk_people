# frozen_string_literal: true

# One size of a picture made from a file in an organization's picture folder (GkPeople::AvatarFolder); made again
# when the file's stamp changes, removed when the file is gone or the folder is switched off
class GkPeopleAvatarFile < ApplicationRecord
  belongs_to :user, class_name: 'Principal'

  validates :size, inclusion: { in: ->(_) { GkPeople::Avatars::SIZES } }
  validates :data, :checksum, :file_name, :file_stamp, presence: true
end
