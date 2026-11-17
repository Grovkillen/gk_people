# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_credentials.
# The credentials.
# No seed data.
class CreateGkPeopleCredentials < ActiveRecord::Migration[6.1]
  def change
    create_table "gk_people_credentials" do |t|
      t.integer "person_id"
      t.integer "organization_id"
      t.string "credential_key", limit: 60, null: false
      t.date "issued_on"
      t.date "valid_to"
      t.string "issuer", limit: 200
      t.string "reference", limit: 100
      t.text "note"
      t.integer "created_by_id"
      t.integer "revoked_by_id"
      t.string "revoke_reason", limit: 255
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.timestamptz "revoked_at", precision: 6
      t.index ["credential_key"], name: "index_gk_people_credentials_on_credential_key"
      t.index ["organization_id"], name: "index_gk_people_credentials_on_organization_id"
      t.index ["person_id"], name: "index_gk_people_credentials_on_person_id"
    end
  end
end
