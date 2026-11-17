# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_avatars.
# An account's own picture: the six small JPEGs, made once on the server, in the database with
# the backup and without file paths. No original is kept. One row per account and size.
class CreateGkPeopleAvatars < ActiveRecord::Migration[6.1]
  def up
    create_table "gk_people_avatars" do |t|
      t.integer "user_id", null: false
      t.integer "size", null: false
      t.binary "data", null: false
      t.string "checksum", limit: 64, null: false
      t.integer "set_by_id"
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["user_id", "size"], name: "index_gk_people_avatars_on_user_id_and_size", unique: true
    end
  end

  def down
    drop_table :gk_people_avatars
  end
end
