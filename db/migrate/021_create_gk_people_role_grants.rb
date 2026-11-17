# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_role_grants.
# The roles granted by the rules.
# No seed data.
class CreateGkPeopleRoleGrants < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_role_grants" do |t|
      t.integer "rule_id", null: false
      t.integer "assignment_id", null: false
      t.integer "person_id", null: false
      t.integer "user_id", null: false
      t.integer "project_id", null: false
      t.integer "role_id", null: false
      t.string "via", limit: 8, default: "holder", null: false
      t.integer "member_role_id"
      t.string "revoke_reason", limit: 20
      t.integer "removed_by_id"
      t.timestamptz "granted_at", null: false, precision: 6
      t.timestamptz "revoked_at", precision: 6
      t.timestamptz "removed_by_hand_at", precision: 6
      t.index ["member_role_id"], name: "index_gk_people_role_grants_on_member_role_id"
      t.index ["rule_id"], name: "index_gk_people_role_grants_on_rule_id"
      t.index ["user_id", "project_id", "role_id"], name: "index_gk_people_role_grants_upr"
    end
  end
end
