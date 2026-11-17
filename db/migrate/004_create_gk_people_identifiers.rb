# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_identifiers.
# The identifiers.
# No seed data.
class CreateGkPeopleIdentifiers < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_identifiers" do |t|
      t.integer "person_id", null: false
      t.integer "scheme_id", null: false
      t.string "value", limit: 300
      t.string "value_digest", limit: 64
      t.boolean "preferred", default: false, null: false
      t.boolean "active", default: true, null: false
      t.date "valid_from"
      t.date "valid_to"
      t.integer "created_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["person_id"], name: "index_gk_people_identifiers_on_person_id"
      t.index ["scheme_id", "value"], name: "index_gk_people_identifiers_on_scheme_id_and_value"
      t.index ["scheme_id", "value_digest"], name: "index_gk_people_identifiers_on_scheme_id_and_value_digest"
    end
  end
end
