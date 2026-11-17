# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_credential_kinds.
# The kinds of credentials.
# No seed data.
class CreateGkPeopleCredentialKinds < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_credential_kinds" do |t|
      t.string "key", limit: 60, null: false
      t.string "name", limit: 200, null: false
      t.text "description"
      t.string "applies_to", limit: 12, default: "person", null: false
      t.integer "renew_months"
      t.integer "position", default: 0, null: false
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["key"], name: "index_gk_people_credential_kinds_on_key", unique: true
    end
  end
end
