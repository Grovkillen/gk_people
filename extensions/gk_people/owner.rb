# frozen_string_literal: true

module GkPeople
  # The instance's owner: the organization marked as owner, the one place every plugin reads who this installation
  # belongs to: file names (revisions), templates, PDF and mail. Not a setting in any plugin. The graphics (logo,
  # colours, fonts) are theme_engine brand_profile's; the name of the system is Redmine's own setting.
  # * owner_langs '*' marks the owner for every language; a list ('en,de') marks an agent or a subsidiary that answers
  #   for documents in those languages. Asked for a language, the one marked for it answers first, then the '*' one.
  # * The short form falls back on the full name, so a site that has not set one gets the name and sees it.
  module Owner
    FIELDS = %w[organisation organisation_short organisation_no organisation_address organisation_city organisation_country
                organisation_phone organisation_email organisation_website organisation_sni].freeze

    module_function

    # no owner without GK GUI Stuff (GkPeople.gui?, gate.rb): organization nil, values empty
    def ready?
      GkPeople.gui? && ::GkPeopleOrganization.column_names.include?('owner_langs')
    rescue StandardError
      false
    end

    def langs_of(org) = org.owner_langs.to_s.split(',').map(&:strip).reject(&:empty?)

    def organization(lang = nil)
      return nil unless ready?

      marked = ::GkPeopleOrganization.where(active: true).where.not(owner_langs: [nil, '']).to_a
      lang = lang.to_s
      marked.detect { |o| lang.present? && langs_of(o).include?(lang) } || marked.detect { |o| langs_of(o).include?('*') }
    end

    # { 'organisation' => ..., 'organisation_short' => ..., ... } for a language; empty values when there is no owner
    def values(lang = nil)
      o = organization(lang)
      return FIELDS.index_with { nil } unless o

      { 'organisation' => o.name, 'organisation_short' => o.short_name.presence || o.name, 'organisation_no' => o.org_no,
        'organisation_address' => o.address, 'organisation_city' => o.city, 'organisation_country' => o.country,
        'organisation_phone' => o.phone, 'organisation_email' => o.email, 'organisation_website' => o.website,
        'organisation_sni' => o.sni }
    end

    # Marking: '*' moves from any other organization to this one (one owner for every language); a language moves
    # from the organization that had it
    def mark!(org, langs)
      list = langs.to_s.split(',').map(&:strip).reject(&:empty?).uniq
      ::GkPeopleOrganization.transaction do
        ::GkPeopleOrganization.where.not(id: org.id).where.not(owner_langs: [nil, '']).find_each do |other|
          rest = langs_of(other) - list
          other.update!(owner_langs: rest.join(',').presence) if rest != langs_of(other)
        end
        org.update!(owner_langs: list.join(',').presence)
      end
    end
  end
end
