# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_imports.
# The imports; the file itself is never kept, only its facts in the options.
# No seed data.
class CreateGkPeopleImports < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_imports" do |t|
      t.string "resource", limit: 20, null: false
      t.integer "user_id"
      t.string "filename", limit: 255
      t.string "source_label", limit: 200, null: false
      t.date "source_on"
      t.string "mode", limit: 10, default: "fill", null: false
      t.text "options_json"
      t.text "rows_json"
      t.string "state", limit: 10, default: "preview", null: false
      t.text "counts_json"
      t.integer "sync_log_id"
      t.datetime "created_at", precision: nil, null: false
      t.datetime "finished_at", precision: nil
      t.index ["state", "created_at"], name: "index_gk_people_imports_on_state_and_created_at"
    end
  end
end
