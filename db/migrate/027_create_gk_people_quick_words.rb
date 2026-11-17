# frozen_string_literal: true

# Merged at 1.00.000: the final state of gk_people_quick_words.
# The quick contacts' words, with the starting words seeded.
# Seed data: the fifteen starting words with a key each, named in English; their other languages are written in
# gk_fields by the key after initialization (GkFields::Translations.seed!, people's init). A word an administrator
# adds has no key.
class CreateGkPeopleQuickWords < ActiveRecord::Migration[6.1]
  # The words 020 seeded, as GkPeopleQuickWord::WORDS
  WORDS = %w[finance hr it purchasing sales marketing communications management ceo production quality environment payroll
             reception board].freeze

  def up
    create_table "gk_people_quick_words" do |t|
      t.string "key", limit: 60
      t.string "name", limit: 60, null: false
      t.integer "position", default: 1, null: false
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false, precision: 6
      t.datetime "updated_at", null: false, precision: 6
      t.index ["key"], name: "index_gk_people_quick_words_on_key", unique: true
    end

    now = Time.current
    # Names quoted by the connection, as in 023
    cols = %w[key name position active created_at updated_at].map { |c| connection.quote_column_name(c) }.join(', ')
    WORDS.each_with_index do |k, i|
      name = I18n.t("label_gk_people_quick_word_#{k}", locale: :en, default: k)
      execute "INSERT INTO #{connection.quote_table_name('gk_people_quick_words')} (#{cols}) VALUES " \
              "(#{quote(k)}, #{quote(name)}, #{i + 1}, #{connection.quoted_true}, #{quote(now)}, #{quote(now)})"
    end
  end

  def down
    drop_table :gk_people_quick_words
  end

  private

  def quote(value) = connection.quote(value)
end
