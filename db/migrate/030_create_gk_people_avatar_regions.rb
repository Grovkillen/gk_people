# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_avatar_regions.
# The part of a picture-folder picture chosen for an account: only the place is kept, as
# fractions of the picture (left, top, side of the square), never the picture.
class CreateGkPeopleAvatarRegions < ActiveRecord::Migration[6.1]
  def up
    create_table "gk_people_avatar_regions" do |t|
      t.integer "user_id", null: false
      t.decimal "x", precision: 6, scale: 5, null: false
      t.decimal "y", precision: 6, scale: 5, null: false
      t.decimal "s", precision: 6, scale: 5, null: false
      t.integer "set_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["user_id"], name: "index_gk_people_avatar_regions_on_user_id", unique: true
    end
  end

  def down
    drop_table :gk_people_avatar_regions
  end
end
