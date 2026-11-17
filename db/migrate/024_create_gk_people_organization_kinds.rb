# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_organization_kinds.
# An organization's kinds, the relations.
# No seed data.
class CreateGkPeopleOrganizationKinds < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_organization_kinds" do |t|
      t.integer "organization_id", null: false
      t.integer "kind_id", null: false
      t.datetime "created_at", precision: nil, null: false
      t.integer "project_id"
      t.date "valid_from"
      t.date "valid_to"
      t.text "reason"
      t.integer "created_by_id"
      t.datetime "updated_at", precision: nil
      t.index ["kind_id"], name: "index_gk_people_organization_kinds_on_kind_id"
      t.index ["organization_id", "kind_id"], name: "index_gk_people_org_relations"
      t.index ["project_id"], name: "index_gk_people_organization_kinds_on_project_id"
    end
  end
end
