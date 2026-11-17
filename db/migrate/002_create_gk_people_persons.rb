# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_persons.
# The persons.
# No seed data.
class CreateGkPeoplePersons < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_persons" do |t|
      t.string "display_name", limit: 200
      t.string "first_name", limit: 100
      t.string "last_name", limit: 100
      t.integer "organization_id"
      t.string "kind", limit: 20, default: "internal", null: false
      t.integer "user_id"
      t.string "email", limit: 200
      t.string "phone", limit: 60
      t.string "title", limit: 120
      t.string "languages", limit: 120
      t.text "notes"
      t.boolean "active", default: true, null: false
      t.string "source", limit: 40
      t.string "external_id", limit: 100
      t.integer "created_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.string "pin_digest", limit: 160
      t.boolean "pin_must_change", default: false, null: false
      t.integer "pin_failures", default: 0, null: false
      t.string "info_source", limit: 200
      t.date "info_source_on"
      t.boolean "quick", default: false, null: false
      t.timestamptz "synced_at", precision: 6
      t.timestamptz "external_deleted_at", precision: 6
      t.timestamptz "pin_set_at", precision: 6
      t.timestamptz "pin_locked_until", precision: 6
      t.index ["created_by_id"], name: "index_gk_people_persons_quick", where: "quick"
      t.index ["last_name", "first_name"], name: "index_gk_people_persons_on_last_name_and_first_name"
      t.index ["organization_id"], name: "index_gk_people_persons_on_organization_id"
      t.index ["source", "external_id"], name: "index_gk_people_persons_on_source_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
      t.index ["user_id"], name: "index_gk_people_persons_on_user_id", unique: true, where: "(user_id IS NOT NULL)"
    end
  end
end
