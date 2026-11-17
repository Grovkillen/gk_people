# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_processing.
# The processing register.
# No seed data.
class CreateGkPeopleProcessing < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_processing" do |t|
      t.string "table_name", limit: 120, null: false
      t.text "purpose"
      t.string "legal_basis", limit: 30
      t.text "retention"
      t.text "visible_to"
      t.integer "updated_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["table_name"], name: "index_gk_people_processing_on_table_name", unique: true
    end
  end
end
