# frozen_string_literal: true

class GkPeopleQuickWord < ApplicationRecord
  self.table_name = 'gk_people_quick_words'

  validates :name, presence: true, length: { maximum: 60 }
  before_validation { self.name = name.to_s.strip }
  before_destroy { throw :abort }

  scope :active, -> { where(active: true) }
  scope :sorted, -> { order(:position, :id) }

  # The starting list's keys, the same as the migration that makes the table seeds: named in English, the other
  # languages are the locales' label_gk_people_quick_word_<key>, written in gk_fields by the key (seed_translations!).
  # A word an administrator adds has no key.
  WORDS = %w[finance hr it purchasing sales marketing communications management ceo production quality environment payroll
             reception board].freeze
  LABEL_PREFIX = 'label_gk_people_quick_word_'

  # A word is never deleted, so a table without rows has never had its list (a new database, or a scenario's wipe): it gets
  # the starting list. A list an administrator has emptied keeps its inactive rows and is left alone.
  def self.ensure_seeded!
    return if exists?

    WORDS.each_with_index do |k, i|
      create!(key: k, name: ::I18n.t("#{LABEL_PREFIX}#{k}", locale: :en, default: k), position: i + 1, active: true)
    end
    seed_translations!
  rescue StandardError
    nil
  end

  # The starting words' other languages in gk_fields; a word an administrator renamed or translated is left alone
  def self.seed_translations!
    return 0 unless defined?(::GkFields::Translations) && ::GkFields::Translations.respond_to?(:seed!)

    ::GkFields::Translations.seed!('GkPeopleQuickWord', label_key_prefix: LABEL_PREFIX)
  end

  # Every text of the active words, in every language: the name, its translations in gk_fields (by the word's id), and
  # for a starting word its own texts in the plugin's locales (by its key), so that the words are known also without
  # gk_fields or before it has written the translations. A line may use any of them.
  def self.texts
    words = active.sorted.to_a
    more = defined?(::GkFields::Translations) && ::GkFields::Translations.respond_to?(:stored) ? ::GkFields::Translations.stored('GkPeopleQuickWord') : {}
    words.flat_map { |w| [w.name, *(more[w.id] || {}).values, *locale_texts(w.key)] }.map { |t| t.to_s.strip }.reject(&:empty?).uniq(&:downcase)
  end

  # A starting word's text in each language the locales have, never another language's text as a fallback
  def self.locale_texts(key)
    return [] if key.blank?

    ::I18n.available_locales.map { |l| ::I18n.t("#{LABEL_PREFIX}#{key}", locale: l, default: '', fallback: false) }.grep(String)
  end

  # ------------------------------------------------------------------ the page: one row per word, a column per language
  # gk_fields keeps the words' other languages (the type is registered and its tables are there)
  def self.translatable?
    t = defined?(::GkFields::Translations) ? ::GkFields::Translations : nil
    return false unless t && %i[texts_for entry_for save_entry seedable?].all? { |m| t.respond_to?(m) } && defined?(t::Row)

    t.seedable?(name)
  rescue StandardError
    false
  end

  # The content languages, the core language first: fields' list (Språk att erbjuda); without fields only the
  # installation's language, since there is nowhere to keep another
  def self.languages
    if translatable? && defined?(::GkFields.content_languages)
      list = ::GkFields.content_languages.map(&:to_s).reject(&:empty?).uniq
      return list if list.any?
    end
    [::Setting.default_language.to_s.presence || 'en']
  end

  def self.core_language = languages.first

  # { lang => text } of the word in the page's languages: the name in the core language unless fields keeps a text
  # in the core language too (a starting word's), the stored translations in the others (fields' texts_for)
  def texts(langs = self.class.languages)
    all = self.class.translatable? ? ::GkFields::Translations.texts_for(self.class.name, id, 'name', name, lang: langs.first) : { langs.first => name }
    langs.index_with { |l| all[l].to_s }
  end

  # The translations fields keeps for the word, without the name
  def stored_texts
    return {} unless self.class.translatable?

    (::GkFieldsTranslation.find_by(record_type: self.class.name, record_id: id, attribute_name: 'name', value_key: nil)&.translations_hash || {})
  end

  # A word without a key gets one when it is saved: w_ and its name, unique; set once and never changed
  def ensure_key!
    return if key.present?

    base = "w_#{name.to_s.parameterize(separator: '_')}".first(50).sub(/_+\z/, '')
    base = 'w' if base.blank?
    candidate = base
    n = 1
    candidate = "#{base}_#{n += 1}" while self.class.where(key: candidate).where.not(id: id).exists?
    self.key = candidate
  end

  # Save the page's table: rows = [{ id:, texts: { lang => text } }] in the order shown. An existing row keeps its word
  # (and key) whatever its text; a row without id is a new word, or a removed one written again; a word whose row
  # was taken away is made inactive (never deleted). The core language is the name; the other languages are saved
  # through fields (save_entry, logged as every other translation change). Returns the number of active words.
  def self.save_table!(rows, user: User.current)
    langs = languages
    core = langs.first
    tr = translatable?
    transaction do
      words = all.to_a
      posted = rows.map { |r| r[:id].to_s.to_i }.reject(&:zero?)
      # a new row may take a word whose row is not on the page (an inactive one, written again)
      free = words.reject { |w| posted.include?(w.id) }
      kept = []
      seen = []
      position = 0
      rows.each do |row|
        texts = langs.index_with { |l| row[:texts].to_h[l].to_s.strip[0, 60] }
        name = texts[core].presence || texts.values.detect(&:present?)
        next if name.blank? || seen.include?(name.downcase)

        word = (row[:id].present? && words.detect { |w| w.id == row[:id].to_i }) ||
               free.detect { |w| kept.exclude?(w) && [w.name, *(tr ? w.stored_texts.values : [])].any? { |x| x.to_s.casecmp?(name) } } || new
        next if kept.include?(word)

        seen << name.downcase
        kept << word
        shown = word.new_record? ? {} : word.texts(langs)
        word.name = name if word.new_record? || name != shown[core]
        word.assign_attributes(position: (position += 1), active: true)
        word.ensure_key!
        word.save! if word.changed?
        save_translations!(word, texts, core, user) if tr
      end
      words.each { |w| w.update!(active: false) if w.active && kept.exclude?(w) }
      kept.size
    end
  end

  # The languages whose text changed, through fields: the core language only where fields keeps a text in it (it is
  # the name otherwise); an emptied language takes its translation away
  def self.save_translations!(word, texts, core, user)
    stored = word.stored_texts
    changes = texts.each_with_object({}) do |(l, text), h|
      next if l == core && !stored.key?(core)

      text = texts[core].presence || word.name if l == core
      h[l] = text if text != stored[l].to_s && (text.present? || stored[l].present?)
    end
    return if changes.empty?

    t = ::GkFields::Translations
    rec = ::GkFieldsTranslation.find_by(record_type: name, record_id: word.id, attribute_name: 'name', value_key: nil)
    row = t::Row.new(record: word, attr: 'name', key: nil, core: word.name, translations: stored, stored_id: rec&.id)
    t.save_entry(t.entry_for(name, row), changes, user, nil)
  end
  private_class_method :save_translations!
end
