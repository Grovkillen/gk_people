# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_groups.
# The people groups.
# No seed data.
class CreateGkPeopleGroups < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_groups" do |t|
      t.string "name", limit: 200, null: false
      t.text "description"
      t.boolean "active", default: true, null: false
      t.string "source", limit: 40
      t.string "external_id", limit: 100
      t.integer "created_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.timestamptz "synced_at", precision: 6
      t.timestamptz "external_deleted_at", precision: 6
      t.index ["name"], name: "index_gk_people_groups_on_name"
      t.index ["source", "external_id"], name: "index_gk_people_groups_on_source_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    end
  end
end
