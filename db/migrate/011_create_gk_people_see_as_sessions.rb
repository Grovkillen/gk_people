# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_see_as_sessions.
# The see-as sessions.
# No seed data.
class CreateGkPeopleSeeAsSessions < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_see_as_sessions" do |t|
      t.integer "elevation_id", null: false
      t.integer "user_id", null: false
      t.integer "person_id"
      t.string "kind", limit: 10, null: false
      t.integer "target_user_id"
      t.integer "target_group_id"
      t.integer "role_id"
      t.integer "project_id"
      t.string "place", limit: 500
      t.text "reason"
      t.string "end_reason", limit: 20
      t.integer "pages", default: 0, null: false
      t.string "last_path", limit: 500
      t.timestamptz "started_at", null: false, precision: 6
      t.timestamptz "ended_at", precision: 6
      t.index ["elevation_id", "started_at"], name: "index_gk_people_see_as_sessions_on_elevation_id_and_started_at"
      t.index ["target_user_id"], name: "index_gk_people_see_as_sessions_on_target_user_id"
    end
  end
end
