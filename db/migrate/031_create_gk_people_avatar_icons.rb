# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_avatar_icons.
# An icon from the icon library chosen for an account: any account, a person's, a shared one or
# a group; the icon's name only.
class CreateGkPeopleAvatarIcons < ActiveRecord::Migration[6.1]
  def up
    create_table "gk_people_avatar_icons" do |t|
      t.integer "user_id", null: false
      t.string "icon", limit: 120, null: false
      t.integer "set_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["user_id"], name: "index_gk_people_avatar_icons_on_user_id", unique: true
    end
  end

  def down
    drop_table :gk_people_avatar_icons
  end
end
