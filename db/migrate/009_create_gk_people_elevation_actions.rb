# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_elevation_actions.
# What was done during an elevation.
# No seed data.
class CreateGkPeopleElevationActions < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_elevation_actions" do |t|
      t.integer "elevation_id", null: false
      t.string "controller", limit: 100, null: false
      t.string "action", limit: 100, null: false
      t.string "http_method", limit: 10
      t.string "path", limit: 500
      t.string "target_id", limit: 100
      t.integer "status"
      t.timestamptz "at", null: false, precision: 6
      t.index ["elevation_id", "at"], name: "index_gk_people_elevation_actions_on_elevation_id_and_at"
    end
  end
end
