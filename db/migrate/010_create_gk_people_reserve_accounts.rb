# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_reserve_accounts.
# The reserve accounts.
# No seed data.
class CreateGkPeopleReserveAccounts < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_reserve_accounts" do |t|
      t.integer "user_id", null: false
      t.integer "owner_user_id"
      t.string "kind", limit: 20, default: "personal", null: false
      t.boolean "active", default: true, null: false
      t.integer "created_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.timestamptz "unlocked_until", precision: 6
      t.timestamptz "last_synced_at", precision: 6
      t.index ["owner_user_id"], name: "index_gk_people_reserve_accounts_on_owner_user_id"
      t.index ["user_id"], name: "index_gk_people_reserve_accounts_on_user_id", unique: true
    end
  end
end
