# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_role_rules.
# The role rules of a responsibility.
# No seed data.
class CreateGkPeopleRoleRules < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_role_rules" do |t|
      t.integer "responsibility_id", null: false
      t.integer "role_id", null: false
      t.string "target", limit: 14, default: "scope", null: false
      t.integer "project_id"
      t.integer "project_type_id"
      t.integer "created_by_id"
      t.datetime "created_at", precision: nil, null: false
      t.index ["responsibility_id"], name: "index_gk_people_role_rules_on_responsibility_id"
    end
  end
end
