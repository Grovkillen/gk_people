# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_schemes.
# The identifier schemes.
# No seed data.
class CreateGkPeopleSchemes < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_schemes" do |t|
      t.string "key", limit: 60, null: false
      t.string "name", limit: 120, null: false
      t.string "kind", limit: 20, default: "contact", null: false
      t.boolean "unique_value", default: false, null: false
      t.string "format", limit: 200
      t.string "link_template", limit: 500
      t.string "icon", limit: 60
      t.text "show_on"
      t.integer "position", default: 1, null: false
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["key"], name: "index_gk_people_schemes_on_key", unique: true
    end
  end
end
