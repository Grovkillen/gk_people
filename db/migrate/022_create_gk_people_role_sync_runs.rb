# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_role_sync_runs.
# The runs of the role synchronisation.
# No seed data.
class CreateGkPeopleRoleSyncRuns < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_role_sync_runs" do |t|
      t.string "kind", limit: 10, null: false
      t.date "run_on"
      t.integer "user_id"
      t.datetime "started_at", precision: nil, null: false
      t.datetime "finished_at", precision: nil
      t.integer "added", default: 0, null: false
      t.integer "removed", default: 0, null: false
      t.integer "deviations", default: 0, null: false
      t.integer "no_account", default: 0, null: false
      t.text "errors_text"
      t.index ["run_on"], name: "index_gk_people_role_sync_runs_on_run_on", unique: true
    end
  end
end
