# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_shared_account_roles.
# The shared accounts' roles.
# No seed data.
class CreateGkPeopleSharedAccountRoles < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_shared_account_roles" do |t|
      t.integer "user_id", null: false
      t.string "principal_type", limit: 10, null: false
      t.integer "principal_id", null: false
      t.integer "project_id", null: false
      t.integer "role_id", null: false
      t.integer "created_by_id"
      t.datetime "created_at", precision: nil, null: false
      t.index ["principal_type", "principal_id"], name: "index_gk_people_shared_account_roles_principal"
      t.index ["user_id", "principal_type", "principal_id", "project_id", "role_id"], name: "index_gk_people_shared_account_roles_unique", unique: true
    end
  end
end
