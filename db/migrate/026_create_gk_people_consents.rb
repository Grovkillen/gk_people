# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_consents.
# The consents.
# No seed data.
class CreateGkPeopleConsents < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_consents" do |t|
      t.integer "person_id", null: false
      t.string "purpose", limit: 200, null: false
      t.integer "project_id"
      t.date "given_on", null: false
      t.date "valid_to"
      t.date "revoked_on"
      t.text "revoke_reason"
      t.integer "recorded_by_id"
      t.integer "revoked_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["person_id"], name: "index_gk_people_consents_on_person_id"
    end
  end
end
