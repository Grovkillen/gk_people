# frozen_string_literal: true

module GkPeople
  # Reserve accounts: the way in if elevation misbehaves.
  # * Personal: for every administrator ticked in the settings the plugin makes <login><suffix> (jimmy_admin; the
  #   suffix is a setting). It is administrator, in no project, gets no mail, has no person of its own and belongs to
  #   its owner: elevations under it show "Jimmy Westberg via jimmy_admin". An owner signing in through LDAP has no
  #   password here; her reserve account keeps a password of its own, set by an administrator. The owner locked or no
  #   longer administrator, or her tick removed: the reserve account is locked.
  # * Shared (optional, for organizations that want one): an existing administrator account chosen in the settings,
  #   belonging to no one.
  # * Never offered as people to pick (@mentions, watchers; PrincipalScopes), and in no project.
  # * Locked by default, and therefore out of Administration > Users' default list (core shows active accounts).
  #   Opened outside the web only: a line "open <login> <minutes>" in control/reserve.txt beside INSTANCE.yml; when
  #   the time has passed, or the line is gone, it is locked again. Unlocking by hand in the users list is undone.
  # Nothing is deleted: a row no longer wanted is made inactive and its account locked.
  module Reserve
    CONTROL = 'reserve.txt'
    KINDS = %w[reserve_created reserve_renamed reserve_retired reserve_opened reserve_closed].freeze
    SYNCED = %w[hashed_password salt passwd_changed_on twofa_scheme twofa_totp_key twofa_totp_last_used_at].freeze

    module_function

    def settings = Elevation.settings
    def suffix = ReserveName.suffix(settings['elevation_reserve_suffix'])
    def owner_ids = Array(settings['elevation_reserve_owners']).map(&:to_i).select(&:positive?).uniq
    def shared_enabled? = settings['elevation_shared_admin'].to_s == '1'
    def shared_id = settings['elevation_shared_admin_id'].to_i

    def rows = ::GkPeopleReserveAccount.active
    def user_ids = rows.pluck(:user_id)
    def reserve?(user) = user.is_a?(::User) && rows.exists?(user_id: user.id)
    def row_for(user) = rows.find_by(user_id: user.id)

    # The person whose reserve account this is (nil for the shared one)
    def owner_person(user)
      r = row_for(user)
      r&.owner ? GkPeople.person_for(r.owner) : nil
    end

    # Who may have a personal reserve account: an active administrator with a person, not a reserve account herself
    def eligible?(owner)
      owner.is_a?(::User) && owner.type == 'User' && owner.active? && owner.read_attribute(:admin) == true &&
        !GkPeople.person_for(owner).nil? && !::GkPeopleReserveAccount.exists?(user_id: owner.id)
    end

    # The settings saved: make, rename and retire so that the rows match the ticks, the suffix and the shared choice
    def reconcile!
      owner_ids.each do |oid|
        owner = ::User.find_by(id: oid)
        ensure_personal!(owner) if owner && eligible?(owner)
      end
      rows.where(kind: 'personal').where.not(owner_user_id: owner_ids).each { |r| retire!(r) }
      reconcile_shared!
      tick!(force: true)
    rescue StandardError => e
      Rails.logger.error("[gk_people] reserve accounts not reconciled: #{e.class}: #{e.message}")
    end

    def ensure_personal!(owner)
      want = ReserveName.login(owner.login, suffix)
      return :bad_login unless want

      row = ::GkPeopleReserveAccount.find_by(owner_user_id: owner.id, kind: 'personal')
      if row&.user
        rename!(row, want)
        row.update_columns(active: true, updated_at: Time.current) unless row.active
        sync!(owner, row)
        return :ok
      end
      return :taken if ::User.where('LOWER(login) = ?', want.downcase).exists?

      user = create_account!(owner, want)
      if row
        row.update_columns(user_id: user.id, active: true, updated_at: Time.current)
      else
        row = ::GkPeopleReserveAccount.create!(user_id: user.id, owner_user_id: owner.id, kind: 'personal', active: true,
                                             created_by_id: ::User.current.logged? ? ::User.current.id : nil)
      end
      sync!(owner, row)
      GkPeople.write(owner, 'reserve_created', { account: GkPeople::Refs.person(user) }) # the reserve account, never its login
      :ok
    end

    def create_account!(owner, login)
      u = ::User.new(language: owner.language, mail_notification: 'none')
      u.login = login
      u.firstname = owner.firstname
      u.lastname = "#{owner.lastname} #{I18n.t(:text_gk_people_reserve_mark, locale: (Setting.default_language.presence || :en))}"[0, 255]
      u.mail = ReserveName.mail(login)
      u.admin = true
      u.status = ::Principal::STATUS_LOCKED
      u.generate_password = true
      u.must_change_passwd = false if u.respond_to?(:must_change_passwd=)
      Thread.current[:gk_people_creating_reserve] = true
      u.save!
      u
    ensure
      Thread.current[:gk_people_creating_reserve] = nil
    end

    # Is a new account being made as a reserve account (people's own hooks leave it without a person)
    def creating? = Thread.current[:gk_people_creating_reserve] == true

    def rename!(row, want)
      u = row.user
      return if u.login == want || ::User.where('LOWER(login) = ?', want.downcase).where.not(id: u.id).exists?

      old = u.login
      u.update_columns(login: want, updated_on: Time.current)
      GkPeople.write(u, 'reserve_renamed', {}) # the account is the target: its logins are not written in the details
    end

    # The owner's password and two-factor to the reserve account, as stored (hash and salt); not for LDAP owners
    def sync!(owner, row)
      return if owner.auth_source_id.present?

      cols = SYNCED & ::User.column_names
      row.user.update_columns(cols.to_h { |c| [c, owner.read_attribute(c)] })
      row.update_columns(last_synced_at: Time.current)
    end

    def retire!(row)
      row.update_columns(active: false, unlocked_until: nil, updated_at: Time.current)
      u = row.user
      return unless u

      u.update_columns(status: ::Principal::STATUS_LOCKED) unless u.status == ::Principal::STATUS_LOCKED
      GkPeople.write(u, 'reserve_retired', { owner: GkPeople::Refs.person(row.owner) })
    end

    def reconcile_shared!
      current = ::GkPeopleReserveAccount.where(kind: 'shared', active: true).to_a
      want = shared_enabled? ? ::User.find_by(id: shared_id, type: 'User') : nil
      want = nil if want && (!want.read_attribute(:admin) || ::GkPeopleReserveAccount.active.where(kind: 'personal').exists?(user_id: want.id))
      current.reject { |r| want && r.user_id == want.id }.each { |r| retire!(r) }
      return unless want

      row = ::GkPeopleReserveAccount.find_by(user_id: want.id)
      if row
        row.update_columns(kind: 'shared', owner_user_id: nil, active: true, updated_at: Time.current)
      else
        ::GkPeopleReserveAccount.create!(user_id: want.id, kind: 'shared', active: true, created_by_id: ::User.current.logged? ? ::User.current.id : nil)
      end
    end

    # An account changed: if it owns a reserve account, the password, two-factor and login follow, and the reserve
    # is locked if the owner is locked or no longer administrator
    def owner_changed(user)
      return unless user.saved_changes.keys.intersect?(SYNCED + %w[login status admin])

      row = ::GkPeopleReserveAccount.active.find_by(owner_user_id: user.id, kind: 'personal')
      return unless row&.user

      sync!(user, row) if user.saved_changes.keys.intersect?(SYNCED)
      if user.saved_changes.key?('login')
        want = ReserveName.login(user.login, suffix)
        rename!(row, want) if want
      end
      tick!(force: true) if user.saved_changes.keys.intersect?(%w[status admin])
    rescue StandardError => e
      Rails.logger.error("[gk_people] reserve account not following #{user.login}: #{e.class}: #{e.message}")
    end

    # control/reserve.txt beside INSTANCE.yml (GK_INSTANCE_FILE): [text, written at] or nil
    def control_file
      f = ENV['GK_INSTANCE_FILE'].to_s
      return nil if f.empty?

      path = File.join(File.dirname(f), 'control', CONTROL)
      File.exist?(path) ? path : nil
    end

    # Open what the file opens and lock everything else, at most every 20 seconds unless the file changed
    @mutex = Mutex.new
    def tick!(force: false)
      path = control_file
      mtime = path ? File.mtime(path) : nil
      now = Time.current
      return if !force && @last_tick && (now - @last_tick) < 20 && mtime == @last_mtime

      @mutex.synchronize do
        @last_tick = now
        @last_mtime = mtime
        wants = path ? Unlock.parse(File.read(path, 4000).to_s.force_encoding('UTF-8').scrub, mtime) : {}
        rows.includes(:user, :owner).find_each { |r| apply!(r, wants, now) }
      end
    rescue StandardError => e
      Rails.logger.error("[gk_people] reserve accounts not checked: #{e.class}: #{e.message}")
    end

    def apply!(row, wants, now)
      u = row.user
      return unless u

      keys = [u.login.downcase, row.owner&.login&.downcase, (row.shared? ? 'shared' : nil)].compact
      until_at = keys.filter_map { |k| wants[k] }.max
      owner_ok = row.shared? || (row.owner && row.owner.active? && row.owner.read_attribute(:admin))
      open = until_at && until_at > now && owner_ok
      status = open ? ::Principal::STATUS_ACTIVE : ::Principal::STATUS_LOCKED
      return if u.status == status && (row.unlocked_until.to_i == (open ? until_at.to_i : 0))

      changed = u.status != status
      u.update_columns(status: status) if changed
      row.update_columns(unlocked_until: open ? until_at : nil)
      GkPeople.write(u, open ? 'reserve_opened' : 'reserve_closed', { until: (open ? until_at : nil), via: CONTROL }) if changed
    end

    # What the settings page says about an administrator's tick: [state, row]
    def state_for(owner)
      row = ::GkPeopleReserveAccount.find_by(owner_user_id: owner.id, kind: 'personal')
      return [:no_person, row] if GkPeople.person_for(owner).nil?
      return [:none, row] unless row&.active && row.user
      return [:ldap, row] if owner.auth_source_id.present?

      [row.open? ? :open : :locked, row]
    end

    module UserPatch
      def self.prepended(base)
        base.after_update_commit :gk_people_reserve_follow
      end

      private

      def gk_people_reserve_follow
        GkPeople::Reserve.owner_changed(self) if GkPeople.plain_user?(self)
      end
    end

    # Reserve accounts are never offered as people to pick: not in @mentions and not when adding watchers, also
    # while one is open. Core's scope for both (Principal.assignable_watchers) leaves them out; they are in no project,
    # so lists made of members (assignee, filters) never had them.
    module PrincipalScopes
      # Without the table (the plugin's migrations not yet run) core's list as it is: a missing table must never break
      # @mentions or the watchers' picker
      def assignable_watchers
        scope = super
        ::GkPeopleReserveAccount.table_exists? ? scope.where.not(id: ::GkPeopleReserveAccount.select(:user_id)) : scope
      rescue StandardError
        super
      end
    end

    module SettingPatch
      def self.prepended(base)
        base.after_commit :gk_people_reserve_reconcile, if: -> { name == 'plugin_gk_people' }
      end

      private

      def gk_people_reserve_reconcile = GkPeople::Reserve.reconcile!
    end
  end
end
