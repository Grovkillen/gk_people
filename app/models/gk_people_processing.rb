# frozen_string_literal: true

# What an administrator wrote about one table in the record of processing (GkPeople::Processing): it is shown over
# the declaration's texts. Empty fields fall back to the declaration.
class GkPeopleProcessing < ApplicationRecord
  self.table_name = 'gk_people_processing'

  validates :table_name, presence: true, uniqueness: true, length: { maximum: 120 }
  validates :legal_basis, inclusion: { in: GkPeople::Privacy::LEGAL_BASES }, allow_blank: true

  def to_s = table_name.to_s
  # gk_fields' translations page names the row by this
  def name = table_name.to_s
end
