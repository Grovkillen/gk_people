# frozen_string_literal: true

# A shared account's own settings (GkPeople::SharedAccounts): whether a PIN is required at that computer
class GkPeopleSharedAccount < ApplicationRecord
  self.table_name = 'gk_people_shared_accounts'

  belongs_to :user
  belongs_to :updated_by, class_name: 'User', optional: true
end
