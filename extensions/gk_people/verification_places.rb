# frozen_string_literal: true

module GkPeople
  # People's places in records' verification status: persons, organizations and core's groups. The ladder and its keys
  # are records' (GkRecords::Verification), the same on every place; people gives each place its row name, its words and
  # which optional levels are on by default, and whether its last step is set only through an approved review in GK
  # Signoff (people's own setting per place, off by default). The administrator ticks the optional levels where people is
  # set up (the plugin settings, records' partial) and changes the words under Translations in GK Fields.
  # Records is optional and may be older than the places: every call is guarded, and the old two-argument
  # register_content is used when records does not take the new keywords. The constants and the pure functions need no
  # Rails (test/core_test.rb).
  module VerificationPlaces
    PLACES = %w[person organization group].freeze
    STEPS = %w[none hypothesis unverified partly_verified verified].freeze
    PARTLY = 'partly_verified'
    UNVERIFIED = 'unverified'
    # The words a place has by default: persons and organizations share the data words, a group has the name words
    WORDS = { 'person' => 'data', 'organization' => 'data', 'group' => 'name' }.freeze
    # Optional levels on by default (hypothesis is off everywhere in people: nobody guesses about a person)
    OPTIONAL_ON = { 'person' => [PARTLY], 'organization' => [PARTLY], 'group' => [] }.freeze
    # The keywords of the place form of register_content
    KEYWORDS = %i[title words optional_on review].freeze

    module_function

    def setting_key(place) = "verification_review_#{place}"

    # The locale keys of a place's row name and words (records' register_content title: and words:)
    def title_key(place) = :"label_gk_people_verification_#{WORDS.fetch(place.to_s)}_title"
    def word_key(place, step) = :"label_gk_people_verification_#{WORDS.fetch(place.to_s)}_#{step}"
    def words(place) = STEPS.to_h { |s| [s, word_key(place, s)] }

    # The options people registers a place with; review is the function records calls per post
    def options(place, review)
      { title: title_key(place), words: words(place), optional_on: OPTIONAL_ON.fetch(place.to_s).dup, review: review }
    end

    # Does a parameter list (Method#parameters) take every keyword of the place form
    def keywords?(params)
      names = Array(params).map { |_, n| n }
      return true if Array(params).any? { |t, _| t == :keyrest }

      KEYWORDS.all? { |k| names.include?(k) }
    end

    def keyword?(params, name) = Array(params).any? { |t, n| n == name || t == :keyrest }

    # Whether the review alone sets the last step on the place: people's own setting, off by default
    def review?(place, settings = nil)
      s = settings || (defined?(::Setting) ? ::Setting.plugin_gk_people : nil)
      s.is_a?(Hash) && s[setting_key(place)].to_s == '1'
    rescue StandardError
      false
    end

    # ------------------------------------------------------------------ records' side, all guarded
    def api = defined?(::GkRecords::Verification) ? ::GkRecords::Verification : nil

    # People's settings as the settings page posts them, while records checks the levels posted with that page
    # before core saves it (the review choice and the levels are saved together); nil otherwise, and with a records
    # that does not offer it, so the stored settings decide
    def posted
      v = api
      s = v.respond_to?(:posted_settings) ? v.posted_settings('gk_people') : nil
      s.is_a?(Hash) ? s : nil
    rescue StandardError
      nil
    end

    def places?
      v = api
      v.respond_to?(:register_content) && keywords?(v.method(:register_content).parameters)
    rescue StandardError
      false
    end

    # Registers the three places, with the facts a review covers (REVIEW_FACTS); the old form without the options when
    # records does not take them
    def register!(facts)
      v = api
      return unless v.respond_to?(:register_content) && v.respond_to?(:facts_text)

      rich = places?
      facts.each do |key, names|
        fn = ->(obj) { v.facts_text(obj, names) }
        if rich && PLACES.include?(key)
          place = key
          v.register_content(key, fn, **options(place, ->(_obj) { VerificationPlaces.review?(place, VerificationPlaces.posted) }))
        else
          v.register_content(key, fn)
        end
      end
    end

    # The rows show on the persons' and organizations' pages without a tracker being chosen
    def request_feature!
      f = defined?(::GkRecords::Features) ? ::GkRecords::Features : nil
      f.request('verification', by: :gk_people) if f.respond_to?(:request)
    rescue ArgumentError
      nil
    end

    # The levels on a place (records' levels: the forced ones, the optional ones that are on, and one that is off but has
    # posts); nil when records does not know places, which means every level as before
    def levels(place)
      v = api
      v.respond_to?(:levels) ? Array(v.levels(place.to_s)).map(&:to_s) : nil
    rescue StandardError
      nil
    end

    # A step's word on the place (records' label with place:), records' own word when it has no places
    def word(step, place)
      v = api
      return '' unless v && step

      if v.respond_to?(:label) && keyword?(v.method(:label).parameters, :place)
        v.label(step.to_s, place: place.to_s).to_s
      else
        v.label(step.to_s).to_s
      end
    rescue StandardError
      ''
    end

    # The row's name on the place
    def title(place)
      v = api
      if v.respond_to?(:title) && v.method(:title).arity != 0
        v.title(place.to_s).to_s
      else
        ::I18n.t(title_key(place))
      end
    rescue StandardError
      ::I18n.t(title_key(place))
    end

    # The words a sentence uses on the place, records' when it has them, else people's defaults
    def word_or_default(step, place)
      w = word(step, place)
      w.presence || ::I18n.t(word_key(place, step))
    end
  end
end
