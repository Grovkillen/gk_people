# frozen_string_literal: true

module GkPeople
  # Account events (triggers manifest, events: people writes the account events): account created, registered
  # (self-registration, waiting for activation), activated, locked and unlocked on the user; member added, member
  # removed and roles changed on the user with the project in the details; and account deleted on the person, who
  # is still there when the account is gone. From the models, so an account made or changed by an admin, the API,
  # LDAP or a sync is caught alike. people loads before records (alphabetical), so records calls register_records!.
  KINDS = %w[account_created account_registered account_activated account_locked account_unlocked member_added member_removed
             roles_changed].freeze

  # Never asks the gate to GK GUI Stuff (gate.rb): the account, the registers and every kind are known to records also
  # while the gate is closed, so the events are written then too (records marks them in their details)
  def self.register_records!
    ::GkRecords::Targets.register('user', model: 'User',
                                           visible: ->(u, user) { user.admin? || user.id == u.id }, editable: ->(_u, user) { user.admin? },
                                           label: ->(u) { u.name }, url: ->(u) { { controller: 'users', action: 'show', id: u.id } })
    (KINDS + Elevation::KINDS + Reserve::KINDS + SeeAs::KINDS + Actor::KINDS + Avatars::KINDS).each { |k| register_event!(k, target: 'user') }
    register_registers!
    register_event!('account_deleted', target: 'person')
    Groups.register_records!
  end

  # reason: the reason goes with the event as its reason, never in the details
  def self.write(user, kind, details, reason: nil)
    return unless defined?(::GkRecords) && ::GkRecords::Targets.find('user') && ::GkRecords::Kinds.find(:event, kind)

    actor = User.current
    ::GkRecords::Events.write(user, kind, details: details, reason: reason.presence, user: actor.logged? ? actor : nil,
                                           origin: actor.logged? ? 'human' : 'system')
  rescue StandardError => e
    Rails.logger.warn("[gk_people] account event #{kind} not written for user #{user.id}: #{e.message}")
  end

  def self.plain_user?(u) = u.is_a?(::User) && u.type == 'User'

  module UserPatch
    def self.prepended(base)
      base.after_create_commit :gk_people_created
      base.after_update_commit :gk_people_status_changed
      base.before_destroy :gk_people_remember_person, prepend: true
      base.after_destroy_commit :gk_people_deleted
    end

    # The person behind the account (People.person_for); nil when there is none
    def gk_people_person = GkPeople.person_for(self)

    private

    def gk_people_created
      return unless GkPeople.plain_user?(self)

      # the account is the target: its login and name are not repeated in the details (records' convention)
      GkPeople.write(self, 'account_created', { status: status, admin: admin?, auth_source: auth_source&.name })
      GkPeople.write(self, 'account_registered', {}) if status == ::Principal::STATUS_REGISTERED
      GkPeople::Accounts.ensure_person!(self) unless GkPeople::Reserve.creating? || GkPeople::Actor.creating_shared?
    rescue StandardError => e
      Rails.logger.warn("[gk_people] no person for the new account #{login}: #{e.message}")
    end

    def gk_people_status_changed
      return unless GkPeople.plain_user?(self) && saved_change_to_status?

      old, new = saved_change_to_status
      kind = if new == ::Principal::STATUS_LOCKED then 'account_locked'
             elsif new == ::Principal::STATUS_ACTIVE && old == ::Principal::STATUS_LOCKED then 'account_unlocked'
             elsif new == ::Principal::STATUS_ACTIVE then 'account_activated'
             end
      GkPeople.write(self, kind, { status: [old, new] }) if kind
    end

    def gk_people_remember_person
      @gk_people_person = GkPeople.plain_user?(self) ? GkPeople.person_for(self) : nil
    end

    # The account is gone, the person stays: the link is broken and the deletion is written on the person
    def gk_people_deleted
      p = @gk_people_person
      return unless p

      p.link_how = 'account_deleted'
      p.update_column(:user_id, nil)
      GkPeople.write_on(p, 'account_deleted', { user_id: id }) # the person is the target: no login in the details
    rescue StandardError => e
      Rails.logger.warn("[gk_people] the deleted account #{login} not written on its person: #{e.message}")
    end
  end

  module MemberPatch
    def self.prepended(base)
      base.after_create_commit :gk_people_member_added
      base.after_destroy_commit :gk_people_member_removed
    end

    private

    def gk_people_member_added
      u = principal
      return unless GkPeople.plain_user?(u)

      GkPeople.write(u, 'member_added', { project: project&.name, project_id: project_id, roles: roles.map(&:name),
                                           role_ids: role_ids, via_group: member_roles.any? { |mr| mr.inherited_from.present? } })
    end

    def gk_people_member_removed
      u = principal
      return unless GkPeople.plain_user?(u)

      GkPeople.write(u, 'member_removed', { project: project&.name, project_id: project_id })
    end
  end

  # A role given or taken on a membership that already existed (a new membership is member_added with its roles,
  # a removed one member_removed); roles that come through a group are the group's, not written per person
  module MemberRolePatch
    def self.prepended(base)
      base.after_create_commit { gk_people_role_changed(:added) }
      base.after_destroy_commit { gk_people_role_changed(:removed) }
    end

    private

    def gk_people_role_changed(how)
      m = ::Member.find_by(id: member_id)
      return if m.nil? || inherited_from.present? # the membership is gone (member_removed says it) or the role is a group's
      return if how == :added && m.created_on && m.created_on > 10.seconds.ago # made with the membership: member_added says it

      u = m.principal
      return unless GkPeople.plain_user?(u)

      GkPeople.write(u, 'roles_changed', { project: m.project&.name, project_id: m.project_id, how => role&.name,
                                            roles: m.roles.map(&:name) })
    rescue StandardError => e
      Rails.logger.warn("[gk_people] roles_changed not written: #{e.message}")
    end
  end
end
