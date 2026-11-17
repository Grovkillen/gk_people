# frozen_string_literal: true

module GkPeople
  # The account as one of the person's identifiers (plugins/people, accounts): user_id on the person, at most one
  # each way. Set by hand on the person's page or the account's admin page, by a match on e-mail when an account is
  # made (match_by_email), or by making a person for a new account (create_person_on_user). The link is an event on
  # the person and can be broken without either side being deleted.
  module Accounts
    module_function

    def settings = (::Setting.plugin_gk_people || {})
    def create_on_user? = settings['create_person_on_user'].to_s != '0'
    def match_by_email? = settings['match_by_email'].to_s != '0'

    def accounts_scope = ::User.where(type: 'User').where.not(status: ::Principal::STATUS_ANONYMOUS)

    # Accounts that have no person (the admin's list to fill, and the choices on a person's page)
    # (reserve accounts never get a person of their own: they belong to their owner's; nor do shared accounts, which
    # are computers: actor_records)
    def unlinked_accounts
      accounts_scope.where.not(id: GkPeoplePerson.with_account.select(:user_id)).where.not(id: ::GkPeopleReserveAccount.select(:user_id))
                    .where.not(id: GkPeople::Actor.shared_users.select(:id)).sorted
    end

    # Of the accounts without a person, those the viewer may see by core's own rule: records' test when records is
    # there (GkRecords::Visibility: visible_user_ids, the same test as visible_user? for a list), otherwise core's
    # User.visible. An administrator sees all, as in core. The choices on a person's page.
    def visible_unlinked_accounts(viewer = ::User.current)
      scope = unlinked_accounts
      return scope if viewer.admin?

      vis = records_visibility
      if vis.respond_to?(:visible_user_ids)
        scope.where(id: vis.visible_user_ids(scope.pluck(:id), viewer).map(&:to_i))
      elsif vis.respond_to?(:visible_user?)
        scope.where(id: scope.to_a.select { |u| vis.visible_user?(u, viewer) }.map(&:id))
      else
        scope.where(id: ::User.visible(viewer).select(:id))
      end
    end

    # May the viewer see this account? The same test: records' visible_user? when records is there, otherwise an
    # administrator and the account herself always, core's built-in users as core shows them, else User.visible
    def visible_account?(user, viewer = ::User.current)
      return true if viewer.admin? || user.id == viewer.id
      return true if user.is_a?(::AnonymousUser) || (defined?(::DeletedUser) && user.is_a?(::DeletedUser))

      vis = records_visibility
      return vis.visible_user?(user, viewer) if vis.respond_to?(:visible_user?)

      ::User.visible(viewer).where(id: user.id).exists?
    end

    def records_visibility = defined?(::GkRecords::Visibility) ? ::GkRecords::Visibility : nil

    # Links the person to the account; an error message (string) when it cannot be done, else nil
    def link!(person, user, how: 'manual', reason: nil)
      return ::I18n.t(:error_gk_people_not_an_account) unless user.is_a?(::User) && user.type == 'User'
      # a reserve account belongs to its owner's person and a shared account is a computer (as unlinked_accounts)
      return ::I18n.t(:error_gk_people_not_an_account) if ::GkPeopleReserveAccount.where(user_id: user.id).exists? || GkPeople::Actor.shared?(user)

      other = GkPeople.person_for(user)
      return ::I18n.t(:error_gk_people_account_taken, name: other.name) if other && other.id != person.id
      return nil if person.user_id == user.id

      person.link_how = how
      person.link_reason = reason
      person.user_id = user.id
      person.save ? nil : person.errors.full_messages.join(', ')
    end

    def unlink!(person, reason: nil)
      return nil if person.user_id.nil?

      person.link_how = 'manual'
      person.link_reason = reason
      person.user_id = nil
      person.save ? nil : person.errors.full_messages.join(', ')
    end

    # A new account gets its person: a person without account and with the same e-mail when exactly one matches,
    # otherwise a new internal person named as the account. Returns the person, or nil when switched off.
    def ensure_person!(user, how: 'account_created', force: false)
      existing = GkPeople.person_for(user)
      return existing if existing
      return nil unless force || create_on_user?
      return nil if GkPeople::Actor.shared?(user)

      if match_by_email? && user.mail.present?
        candidates = GkPeoplePerson.where(user_id: nil).where('lower(email) = lower(?)', user.mail).to_a
        if candidates.size == 1
          link!(candidates.first, user, how: 'email_match')
          return candidates.first
        end
      end
      person = GkPeoplePerson.new(first_name: user.firstname, last_name: user.lastname, email: user.mail, kind: 'internal',
                                created_by_id: (User.current.logged? ? User.current.id : nil))
      person.user_id = user.id
      person.link_how = how
      person.save!
      person
    end

    # Every account without a person gets one (the admin's button; also after the plugin is installed on an
    # instance that already has accounts). Returns how many were made or linked.
    def fill_missing!
      n = 0
      unlinked_accounts.reorder(:id).find_each do |u|
        n += 1 if ensure_person!(u, how: 'filled_in', force: true)
      rescue StandardError => e
        Rails.logger.warn("[gk_people] no person for account #{u.login}: #{e.message}")
      end
      n
    end
  end
end
