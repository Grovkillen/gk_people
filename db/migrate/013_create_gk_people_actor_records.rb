# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_actor_records.
# The actor records.
# No seed data.
class CreateGkPeopleActorRecords < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_actor_records" do |t|
      t.integer "issue_id"
      t.integer "journal_id"
      t.integer "person_id", null: false
      t.integer "user_id", null: false
      t.string "captured_by", limit: 10, default: "search", null: false
      t.integer "scheme_id"
      t.string "action", limit: 20, default: "updated", null: false
      t.integer "time_entry_id"
      t.integer "project_id"
      t.text "details"
      t.timestamptz "captured_at", null: false, precision: 6
      t.index ["issue_id"], name: "index_gk_people_actor_records_on_issue_id"
      t.index ["journal_id"], name: "index_gk_people_actor_records_on_journal_id"
      t.index ["person_id", "captured_at"], name: "index_gk_people_actor_records_on_person_id_and_captured_at"
      t.index ["time_entry_id"], name: "index_gk_people_actor_records_on_time_entry_id"
    end
  end
end
