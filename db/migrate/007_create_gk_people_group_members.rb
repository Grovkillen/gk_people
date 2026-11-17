# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_group_members.
# The people groups' members.
# No seed data.
class CreateGkPeopleGroupMembers < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_group_members" do |t|
      t.integer "group_id", null: false
      t.integer "person_id", null: false
      t.integer "position", default: 1, null: false
      t.integer "created_by_id"
      t.datetime "created_at", precision: nil, null: false
      t.index ["group_id", "person_id"], name: "index_gk_people_group_members_on_group_id_and_person_id", unique: true
      t.index ["person_id"], name: "index_gk_people_group_members_on_person_id"
    end
  end
end
