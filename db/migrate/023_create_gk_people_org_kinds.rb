# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_org_kinds.
# The kinds of organization, with the six kinds of the old fixed list seeded.
# Seed data: the six kinds, named in English; their other languages are written in gk_fields after initialization
# (GkFields::Translations.seed!, people's init).
class CreateGkPeopleOrgKinds < ActiveRecord::Migration[6.1]
  # The kinds 015 seeded: the old fixed list, each named in English whatever the default language is
  KINDS = %w[customer supplier authority partner internal other].freeze

  def up
    create_table "gk_people_org_kinds" do |t|
      t.string "key", limit: 60, null: false
      t.string "name", limit: 200, null: false
      t.text "description"
      t.integer "position", default: 1, null: false
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["key"], name: "index_gk_people_org_kinds_on_key", unique: true
    end

    now = Time.current
    # Names quoted by the connection: key is a reserved word on some databases
    cols = %w[key name position active created_at updated_at].map { |c| connection.quote_column_name(c) }.join(', ')
    KINDS.each_with_index do |k, i|
      name = I18n.t("label_gk_people_org_kind_#{k}", locale: :en, default: k.humanize)
      execute("INSERT INTO #{connection.quote_table_name('gk_people_org_kinds')} (#{cols}) VALUES " \
              "(#{quote(k)}, #{quote(name)}, #{i + 1}, #{quote(true)}, #{quote(now)}, #{quote(now)})")
    end
  end

  def down
    drop_table :gk_people_org_kinds
  end

  private

  def quote(value) = connection.quote(value)
end
