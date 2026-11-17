# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_assignments.
# The assignments of responsibilities.
# No seed data.
class CreateGkPeopleAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_assignments" do |t|
      t.integer "responsibility_id", null: false
      t.integer "person_id", null: false
      t.string "scope_type", limit: 12, default: "organization", null: false
      t.integer "scope_id"
      t.date "valid_from"
      t.date "valid_to"
      t.integer "deputy_person_id"
      t.date "deputy_valid_from"
      t.date "deputy_valid_to"
      t.text "note"
      t.integer "created_by_id"
      t.datetime "created_at", precision: nil, null: false
      t.integer "ended_by_id"
      t.timestamptz "ended_at", precision: 6
      t.index ["deputy_person_id"], name: "index_gk_people_assignments_on_deputy_person_id"
      t.index ["person_id"], name: "index_gk_people_assignments_on_person_id"
      t.index ["responsibility_id", "scope_type", "scope_id"], name: "index_gk_people_assignments_scope"
    end
  end
end
