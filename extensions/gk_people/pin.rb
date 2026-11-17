# frozen_string_literal: true

module GkPeople
  # token_input and PIN: at a shared computer one can say who one is with a badge (a reader in keyboard mode sends
  # the value and Enter), and an account can require a PIN as well (per shared account, on its matrix). A PIN is set
  # by the person herself (Mitt konto) or, for a person without an account, given by an administrator as a start
  # code that must be changed the first time at the computer. Kept as PBKDF2 (OpenSSL, no new dependency), never in
  # clear text. Five wrong in a row lock the PIN for 15 minutes.
  module Pin
    ITERATIONS = 100_000
    FORMAT = /\A\d{4,8}\z/
    MAX_FAILURES = 5
    LOCK_MINUTES = 15

    module_function

    def ready?
      ::GkPeoplePerson.column_names.include?('pin_digest')
    rescue StandardError
      false
    end

    def valid_format?(pin) = pin.to_s.match?(FORMAT)

    def digest(pin, salt = SecureRandom.hex(16))
      raw = OpenSSL::KDF.pbkdf2_hmac(pin.to_s, salt: salt, iterations: ITERATIONS, length: 32, hash: 'sha256')
      "pbkdf2_sha256$#{ITERATIONS}$#{salt}$#{raw.unpack1('H*')}"
    end

    def matches?(stored, pin)
      _, iter, salt, hex = stored.to_s.split('$', 4)
      return false if hex.to_s.empty?

      raw = OpenSSL::KDF.pbkdf2_hmac(pin.to_s, salt: salt, iterations: iter.to_i, length: 32, hash: 'sha256')
      ActiveSupport::SecurityUtils.secure_compare(raw.unpack1('H*'), hex)
    end

    def set?(person) = person&.pin_digest.present?
    def locked?(person) = person&.pin_locked_until.present? && person.pin_locked_until > Time.current
    def must_change?(person) = person&.pin_must_change == true

    # by: 'self' or 'admin'; an admin's start code must be changed the first time
    def set!(person, pin, by:)
      raise ArgumentError, 'format' unless valid_format?(pin)

      person.update_columns(pin_digest: digest(pin), pin_set_at: Time.current, pin_must_change: by == 'admin', pin_failures: 0,
                            pin_locked_until: nil)
      GkPeople.write_on(person, 'person_pin_set', { by: by })
    end

    # :ok, :wrong, :locked or :none; a wrong PIN counts, and the fifth in a row locks it
    def check(person, pin)
      return :none unless set?(person)
      return :locked if locked?(person)

      if matches?(person.pin_digest, pin)
        person.update_columns(pin_failures: 0) if person.pin_failures.to_i.positive?
        return :ok
      end
      n = person.pin_failures.to_i + 1
      if n >= MAX_FAILURES
        person.update_columns(pin_failures: 0, pin_locked_until: Time.current + LOCK_MINUTES.minutes)
        GkPeople.write_on(person, 'person_pin_locked', { minutes: LOCK_MINUTES })
        :locked
      else
        person.update_columns(pin_failures: n)
        :wrong
      end
    end
  end

  # A shared account's own settings (one row per account): whether a PIN is required at that computer
  module SharedAccounts
    module_function

    def ready?
      ::GkPeopleSharedAccount.table_exists?
    rescue StandardError
      false
    end

    def require_pin?(user) = ready? && user&.id && ::GkPeopleSharedAccount.where(user_id: user.id, require_pin: true).exists?

    def set_require_pin!(user, on)
      row = ::GkPeopleSharedAccount.find_or_initialize_by(user_id: user.id)
      return if row.persisted? && row.require_pin == on

      row.update!(require_pin: on, updated_by_id: (::User.current.logged? ? ::User.current.id : nil), updated_at: Time.current)
      GkPeople.write(user, 'shared_pin_changed', { require_pin: on })
    end
  end

  # A badge (or card, barcode, QR) read at a shared computer: the person, among the token schemes, and which scheme
  module Identify
    def self.by_token(value)
      v = value.to_s.strip
      return [nil, nil] if v.empty?

      ::GkPeopleScheme.active.where(kind: 'token').each do |scheme|
        p = lookup(scheme.key, v)
        return [p, scheme] if p
      end
      [nil, nil]
    end
  end
end
