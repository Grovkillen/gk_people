# frozen_string_literal: true

module GkPeople
  # credentials: credentials and training of persons and organizations, and the credentials a responsibility
  # requires.
  # * The kinds are data (Administration > Intygstyper, scenario): who may hold one and how many months it is valid.
  # * A credential: kind, issued, valid until, issuer, number, the proof as attachments. Never removed: revoked with
  #   a reason. Status: valid, expiring (its last day within the warning days, a setting), not yet, expired, revoked.
  # * Who sees: a credential in force is seen by anyone who sees the registers; an expired or revoked one of a person
  #   only by herself and those who handle credentials or responsibilities. An organization's are seen by all who
  #   see the registers.
  # * A responsibility may require kinds (required_credential_keys). Assigning someone who lacks one goes through
  #   with a warning, and the page Organisation shows the holder as lacking (orange) until the credential is there.
  # * Expiry is a mark for now (person page, Intyg, Organisation); the renewal issue comes with recurring.
  # Ruby API: Credentials.valid?(holder, key, on:), lacking(person, responsibility, on:), for_holder(holder).
  module Credentials
    EVENTS = %w[credential_added credential_changed credential_revoked].freeze
    STATUSES = %i[valid expiring not_yet expired revoked].freeze

    module_function

    def ready?
      ::GkPeopleCredential.table_exists?
    rescue StandardError
      false
    end

    def warn_days
      n = (Setting.plugin_gk_people || {})['credential_warn_days'].to_i
      n.positive? ? n : 30
    rescue StandardError
      30
    end

    def manage?(user = ::User.current) = user.admin? || user.allowed_to?(:gk_people_manage_credentials, nil, global: true)

    # Expired and revoked credentials of a person: herself, and those who handle credentials or responsibilities
    def see_lapsed?(holder, user = ::User.current)
      return true if holder.is_a?(::GkPeopleOrganization)
      return true if manage?(user) || Responsibilities.manage?(user)

      holder.is_a?(::GkPeoplePerson) && holder.user_id.present? && holder.user_id == user.id
    end

    def visible?(credential, user = ::User.current)
      holder = credential.holder
      return false unless holder && (Access.view?(user) || (holder.is_a?(::GkPeoplePerson) && holder.user_id == user.id && user.logged?))
      return true if credential.in_force? || credential.status == :not_yet

      see_lapsed?(holder, user)
    end

    def column_for(holder) = holder.is_a?(::GkPeopleOrganization) ? :organization_id : :person_id

    # A holder's credentials as the user may see them, newest end first
    def for_holder(holder, user = ::User.current)
      rows = ::GkPeopleCredential.where(column_for(holder) => holder.id).sorted.to_a
      rows.select { |c| c.visible?(user) }
    end

    # Holds a credential of the kind that is in force on the day
    def valid?(holder, key, on: ::User.current.today)
      return false if holder.nil?

      ::GkPeopleCredential.in_force(on).where(column_for(holder) => holder.id, credential_key: key.to_s).exists?
    end

    def required_keys(responsibility)
      JSON.parse(responsibility.required_credential_keys.presence || '[]').map(&:to_s)
    rescue JSON::ParserError
      []
    end

    def set_required!(responsibility, keys)
      list = Array(keys).map(&:to_s).reject(&:blank?).uniq
      responsibility.required_credential_keys = list.empty? ? nil : list.to_json
    end

    # The kinds a responsibility requires that the person does not hold in force on the day
    def lacking(person, responsibility, on: ::User.current.today)
      keys = required_keys(responsibility)
      return [] if keys.empty? || person.nil?

      have = ::GkPeopleCredential.in_force(on).where(person_id: person.id, credential_key: keys).distinct.pluck(:credential_key)
      keys - have
    end

    def kind_names(keys)
      kinds = ::GkPeopleCredentialKind.where(key: keys).index_by(&:key)
      keys.map { |k| kinds[k]&.name || k }
    end

    # The credentials that need attention: in force but expiring, or lapsed and not replaced by one in force of the
    # same kind; only those the user may see
    def attention(user = ::User.current, on: ::User.current.today)
      rows = ::GkPeopleCredential.not_revoked.where('gk_people_credentials.valid_to IS NOT NULL AND gk_people_credentials.valid_to <= ?', on + warn_days)
                               .includes(:person, :organization).order(:valid_to).to_a
      current = ::GkPeopleCredential.in_force(on).where('gk_people_credentials.valid_to IS NULL OR gk_people_credentials.valid_to > ?', on + warn_days)
                                  .pluck(:person_id, :organization_id, :credential_key).to_set
      rows.reject { |c| current.include?([c.person_id, c.organization_id, c.credential_key]) }.select { |c| c.visible?(user) }
    end

    def holder_name(holder) = holder.respond_to?(:name) ? holder.name : holder.to_s

    def write(credential, kind, details, reason: nil)
      GkPeople.write_on(credential.holder, kind, details.merge(credential: credential.credential_key, credential_id: credential.id),
                         reason: reason)
    end

    def revoke!(credential, reason:, by: ::User.current)
      return false if credential.revoked_at

      credential.revoked_at = Time.current
      credential.revoked_by_id = by&.logged? ? by.id : nil
      credential.revoke_reason = reason.to_s.strip.presence
      ok = credential.save
      # The reason goes with the event as its reason (a note), no longer in the details; records still reads
      # details['reason'] back for the older events (GkRecordsEvent#details_reason)
      write(credential, 'credential_revoked', {}, reason: credential.revoke_reason) if ok
      ok
    end
  end
end
