# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_organizations.
# The organizations.
# No seed data.
# The first migration's down runs last at redmine:plugins:migrate NAME=gk_people VERSION=0: it also takes away the
# plugin's row in core's settings and the gk_people_ keys in each person's preferences.
class CreateGkPeopleOrganizations < ActiveRecord::Migration[6.1]
  def change
    reversible { |dir| dir.down { strip_preferences('gk_people_') } }
    reversible { |dir| dir.down { Setting.where(name: 'plugin_gk_people').delete_all } }
    create_table "gk_people_organizations" do |t|
      t.string "name", limit: 200, null: false
      t.string "org_no", limit: 40
      t.text "address"
      t.string "country", limit: 2
      t.text "notes"
      t.boolean "active", default: true, null: false
      t.string "approval_status", limit: 20, default: "not_assessed", null: false
      t.date "approval_valid_to"
      t.integer "approved_by_id"
      t.string "risk_class", limit: 20
      t.string "source", limit: 40
      t.string "external_id", limit: 100
      t.integer "created_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.string "info_source", limit: 200
      t.date "info_source_on"
      t.string "city", limit: 100
      t.string "sni", limit: 20
      t.string "short_name", limit: 40
      t.string "phone", limit: 60
      t.string "email", limit: 200
      t.string "website", limit: 255
      t.string "owner_langs", limit: 60
      t.decimal "location_n", precision: 12, scale: 3
      t.decimal "location_e", precision: 12, scale: 3
      t.string "location_crs", limit: 20, default: "EPSG:3006"
      t.integer "parent_id"
      t.boolean "quick", default: false, null: false
      t.timestamptz "approved_at", precision: 6
      t.timestamptz "synced_at", precision: 6
      t.timestamptz "external_deleted_at", precision: 6
      t.boolean "avatar_folder_on", default: false, null: false
      t.string "avatar_folder", limit: 500
      t.string "avatar_name_rule", limit: 80, default: "login", null: false
      t.string "org_no_digits", limit: 40
      t.boolean "avatar_hide_allowed", default: false, null: false
      t.boolean "name_hide_allowed", default: false, null: false
      t.string "org_form", limit: 100
      t.string "size_class", limit: 60
      t.date "deregistered_on"
      t.index ["created_by_id"], name: "index_gk_people_organizations_quick", where: "quick"
      t.index ["name"], name: "index_gk_people_organizations_on_name"
      t.index ["org_no_digits"], name: "index_gk_people_organizations_on_org_no_digits"
      t.index ["parent_id"], name: "index_gk_people_organizations_on_parent_id"
      t.index ["source", "external_id"], name: "index_gk_people_organizations_on_source_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    end
  end

  private

  # Uninstalling (down to 0, this migration last) takes the plugin's own keys out of the users' preferences in core's
  # user_preferences; the rows and core's own keys stay. In Ruby, so that it is the same on every database.
  def strip_preferences(prefix)
    ::UserPreference.reset_column_information
    ::UserPreference.find_each do |pref|
      others = pref.read_attribute(:others)
      next unless others.respond_to?(:keys) && others.keys.any? { |k| k.to_s.start_with?(prefix) }

      pref.update_column(:others, others.reject { |k, _| k.to_s.start_with?(prefix) })
    end
  end
end
