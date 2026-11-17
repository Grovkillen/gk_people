# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_shared_accounts.
# The shared accounts and their PIN rule.
# No seed data.
class CreateGkPeopleSharedAccounts < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_shared_accounts" do |t|
      t.integer "user_id", null: false
      t.boolean "require_pin", default: false, null: false
      t.integer "updated_by_id"
      t.datetime "updated_at", precision: nil
      t.index ["user_id"], name: "index_gk_people_shared_accounts_on_user_id", unique: true
    end
  end
end
