# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_responsibilities.
# The responsibilities.
# No seed data.
class CreateGkPeopleResponsibilities < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_responsibilities" do |t|
      t.string "key", limit: 60, null: false
      t.string "name", limit: 200, null: false
      t.text "description"
      t.string "kind", limit: 10, default: "function", null: false
      t.integer "wiki_page_id"
      t.text "required_credential_keys"
      t.integer "position", default: 0, null: false
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.boolean "role_sync", default: false, null: false
      t.index ["key"], name: "index_gk_people_responsibilities_on_key", unique: true
    end
  end
end
