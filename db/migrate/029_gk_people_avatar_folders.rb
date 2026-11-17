# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_avatar_files.
# The picture folder per organization: where the pictures are, how a file is named, off by
# default; and the pictures made from the folder's files, one row per account and size, made again when the file
# changes (the file's stamp: modified time and length). The files themselves are never copied.
class GkPeopleAvatarFolders < ActiveRecord::Migration[6.1]
  # The folder's columns on gk_people_organizations are in that table's final state (001)
  def up
    create_table "gk_people_avatar_files" do |t|
      t.integer "user_id", null: false
      t.integer "size", null: false
      t.binary "data", null: false
      t.string "checksum", limit: 64, null: false
      t.string "file_name", limit: 255, null: false
      t.string "file_stamp", limit: 40, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["user_id", "size"], name: "index_gk_people_avatar_files_on_user_id_and_size", unique: true
    end
  end

  def down
    drop_table :gk_people_avatar_files
  end
end
