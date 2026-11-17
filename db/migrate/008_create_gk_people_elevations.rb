# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_elevations.
# The elevations.
# No seed data.
class CreateGkPeopleElevations < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_elevations" do |t|
      t.integer "user_id", null: false
      t.integer "person_id"
      t.string "auth_method", limit: 20, default: "password", null: false
      t.text "reason"
      t.string "end_reason", limit: 20
      t.string "ip", limit: 60
      t.timestamptz "started_at", null: false, precision: 6
      t.timestamptz "expires_at", null: false, precision: 6
      t.timestamptz "last_activity_at", precision: 6
      t.timestamptz "ended_at", precision: 6
      t.index ["user_id", "started_at"], name: "index_gk_people_elevations_on_user_id_and_started_at"
    end
  end
end
