# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_sync_log.
# The synchronisation log.
# No seed data.
class CreateGkPeopleSyncLog < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_sync_log" do |t|
      t.string "source", limit: 40, null: false
      t.string "resource", limit: 20, null: false
      t.integer "user_id"
      t.integer "received", default: 0, null: false
      t.integer "created", default: 0, null: false
      t.integer "updated", default: 0, null: false
      t.integer "unchanged", default: 0, null: false
      t.integer "rejected", default: 0, null: false
      t.text "errors_json"
      t.timestamptz "started_at", null: false, precision: 6
      t.timestamptz "finished_at", precision: 6
      t.index ["source", "started_at"], name: "index_gk_people_sync_log_on_source_and_started_at"
    end
  end
end
