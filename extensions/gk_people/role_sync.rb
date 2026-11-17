# frozen_string_literal: true

module GkPeople
  # role_sync: Redmine roles that follow from a responsibility.
  # * Off for the instance by default (setting role_sync_enabled), switched on per responsibility (role_sync).
  # * Rules on the responsibility: a role in the assignment's own project (scope), in a named project, or in every
  #   project of a project type (gk_project_types, also projects made later).
  # * Who: the holder while the assignment is in force, and the deputy while she stands in (her period, or the
  #   holder's account locked). Only a person with an active account; the others are counted as no_account.
  # * When: at once when an assignment, a deputy, a rule or the switch changes, by hand (Synka nu), and once a day:
  #   as the job people_role_sync in ops when ops runs in the process, otherwise at the first web request after
  #   midnight (a unique row per day is the lock), so it never stops for want of ops.
  # * Only what people made is removed (gk_people_role_grants.member_role_id); a role that was there already is left
  #   alone. A role people gave that someone removes by hand is a deviation: shown with who and when, never put back.
  # * Journaled as events on the person (role_granted, role_revoked, role_removed_by_hand).
  module RoleSync
    EVENTS = %w[role_granted role_revoked role_removed_by_hand].freeze
    THREAD_KEY = :gk_people_role_sync_running

    module_function

    def ready?
      ::GkPeopleRoleGrant.table_exists?
    rescue StandardError
      false
    end

    def enabled?
      ready? && (Setting.plugin_gk_people || {})['role_sync_enabled'].to_s == '1'
    rescue StandardError
      false
    end

    def running? = Thread.current[THREAD_KEY] == true

    def projects_alive = ::Project.where(status: [::Project::STATUS_ACTIVE, ::Project::STATUS_CLOSED])

    def project_type_ids(type_id)
      return [] unless defined?(::GkProjectTypesAssignment) && type_id

      ::GkProjectTypesAssignment.where(type_id: type_id).pluck(:project_id)
    end

    # The projects a rule gives its role in, for one assignment
    def projects_for(rule, assignment)
      ids = case rule.target
            when 'scope' then assignment.scope_type == 'project' ? [assignment.scope_id] : []
            when 'project' then [rule.project_id]
            when 'project_type' then project_type_ids(rule.project_type_id)
            else []
            end
      projects_alive.where(id: ids.compact).pluck(:id)
    end

    # Who gets the role through an assignment today: [[person, :holder], [deputy, :deputy]]
    def recipients(assignment, on)
      list = [[assignment.person, 'holder']]
      deputy = assignment.deputy
      standing_in = deputy && (assignment.deputy_period_covers?(on) || assignment.person&.user&.locked?)
      list << [deputy, 'deputy'] if standing_in
      list
    end

    # What should be: { key => { rule:, assignment:, person:, user_id:, project_id:, role_id:, via: } }, and how many
    # recipients had no active account. On the server's day: roles are the instance's, not one person's, and Rails'
    # own zone (Date.current) is UTC in Redmine.
    def desired(on = ::Date.today)
      want = {}
      no_account = 0
      rules = ::GkPeopleRoleRule.joins(:responsibility).where(gk_people_responsibilities: { role_sync: true, active: true }).includes(:responsibility).to_a
      rules.group_by(&:responsibility_id).each do |rid, rs|
        ::GkPeopleAssignment.in_force(on).where(responsibility_id: rid).includes(:person, :deputy).find_each do |a|
          recipients(a, on).each do |person, via|
            user = person&.user
            unless person&.active && user&.active?
              no_account += 1
              next
            end
            rs.each do |rule|
              projects_for(rule, a).each do |pid|
                k = [rule.id, a.id, via, user.id, pid, rule.role_id]
                want[k] = { rule: rule, assignment: a, person: person, user_id: user.id, project_id: pid, role_id: rule.role_id, via: via }
              end
            end
          end
        end
      end
      [want, no_account]
    end

    # The membership role of a user for a role in a project, any (own, a group's, another grant's)
    def member_role_for(user_id, project_id, role_id)
      ::MemberRole.joins(:member).where(members: { user_id: user_id, project_id: project_id }, role_id: role_id).first
    end

    def add_role!(user_id, project_id, role_id)
      member = ::Member.find_or_initialize_by(user_id: user_id, project_id: project_id)
      mr = ::MemberRole.new(role_id: role_id)
      member.member_roles << mr
      member.save!
      mr
    end

    # Runs the sync: kind daily, change, manual or scenario. Returns the run, or nil when off.
    # enabled: the caller's own answer to whether the sync is on (a scenario that switched it on itself), instead of
    # the setting read through core's settings cache, which another thread may refill with the value from before an
    # uncommitted change
    def run!(kind: 'change', run: nil, enabled: nil)
      return nil unless enabled.nil? ? enabled? : (ready? && enabled)
      return nil if running?

      Thread.current[THREAD_KEY] = true
      run ||= ::GkPeopleRoleSyncRun.create!(kind: kind, user_id: ::User.current.logged? ? ::User.current.id : nil, started_at: Time.current)
      errors = []
      counts = Hash.new(0)
      want, counts[:no_account] = desired
      active = ::GkPeopleRoleGrant.active.to_a
      by_key = active.index_by(&:key)
      wanted_uprs = want.values.map { |w| [w[:user_id], w[:project_id], w[:role_id]] }.to_set

      # 1. no longer wanted: revoke; remove the role only if people made it and nothing else wants it
      active.each do |g|
        next if want.key?(g.key)

        begin
          reason = revoke_reason(g)
          pass_on = g.member_role_id && wanted_uprs.include?(g.upr)
          if g.member_role_id && !pass_on && (mr = ::MemberRole.find_by(id: g.member_role_id))
            mr.destroy
          end
          other = pass_on ? active.detect { |o| o.id != g.id && o.upr == g.upr && want.key?(o.key) && o.member_role_id.nil? && o.removed_by_hand_at.nil? } : nil
          other&.update_columns(member_role_id: g.member_role_id)
          g.update_columns(revoked_at: Time.current, revoke_reason: reason)
          handed[g.upr] = g.member_role_id if pass_on && other.nil?
          counts[:removed] += 1
          event(g, 'role_revoked', reason: reason)
        rescue StandardError => e
          errors << "revoke #{g.id}: #{e.message}"
        end
      end

      # 2. still wanted: a role people made that is gone is a deviation (not put back); a covered one that is gone
      #    becomes people's own
      active.each do |g|
        next unless want.key?(g.key)

        begin
          if g.member_role_id && !::MemberRole.exists?(g.member_role_id)
            if g.removed_by_hand_at.nil?
              g.update_columns(removed_by_hand_at: Time.current, member_role_id: nil)
              event(g, 'role_removed_by_hand', by: nil)
            else
              g.update_columns(member_role_id: nil)
            end
            counts[:deviations] += 1
          elsif g.removed_by_hand_at
            mr = member_role_for(g.user_id, g.project_id, g.role_id)
            if mr # put back by hand: no longer a deviation, and the role is not people's
              g.update_columns(removed_by_hand_at: nil, removed_by_id: nil)
            else
              counts[:deviations] += 1
            end
          elsif g.member_role_id.nil? && member_role_for(g.user_id, g.project_id, g.role_id).nil?
            g.update_columns(member_role_id: add_role!(g.user_id, g.project_id, g.role_id).id)
            counts[:added] += 1
          end
        rescue StandardError => e
          errors << "check #{g.id}: #{e.message}"
        end
      end

      # 3. wanted and not granted: add the role (or note that it was there already)
      want.each do |k, w|
        next if by_key.key?(k)

        begin
          upr = [w[:user_id], w[:project_id], w[:role_id]]
          mine = handed.delete(upr)
          if mine.nil? && member_role_for(*upr).nil?
            mine = add_role!(*upr).id
            counts[:added] += 1
          end
          g = ::GkPeopleRoleGrant.create!(rule_id: w[:rule].id, assignment_id: w[:assignment].id, person_id: w[:person].id, user_id: w[:user_id],
                                        project_id: w[:project_id], role_id: w[:role_id], via: w[:via], member_role_id: mine,
                                        granted_at: Time.current)
          event(g, 'role_granted', covered: mine.nil?)
        rescue StandardError => e
          errors << "grant #{k.inspect}: #{e.message}"
        end
      end

      run.update_columns(finished_at: Time.current, added: counts[:added], removed: counts[:removed], deviations: counts[:deviations],
                         no_account: counts[:no_account], errors_text: errors.presence&.join("\n"))
      run
    ensure
      Thread.current[THREAD_KEY] = nil
      Thread.current[HANDED_KEY] = nil
    end

    # Roles handed over in this run from a revoked grant to a new one (the same user, project and role)
    # (kept per thread: two runs in two threads must not share it)
    HANDED_KEY = :gk_people_role_sync_handed
    def handed = (Thread.current[HANDED_KEY] ||= {})

    def revoke_reason(g)
      a = g.assignment
      rule = g.rule
      return 'rule_removed' if rule.nil?
      return 'sync_off' unless rule.responsibility&.role_sync && rule.responsibility&.active
      return 'project_gone' unless projects_alive.exists?(id: g.project_id)
      return 'no_account' unless g.user&.active?
      return 'ended' if a.nil? || !a.in_force?(::Date.today)
      return 'standing_in_over' if g.via == 'deputy'

      'ended'
    end

    def event(grant, kind, extra = {})
      person = grant.person
      return unless person

      GkPeople.write_on(person, kind, { project: grant.project&.name, project_id: grant.project_id, role: grant.role&.name, via: grant.via,
                                         responsibility: grant.rule&.responsibility&.key }.merge(extra))
    end

    JOB_KEY = 'people_role_sync'

    # ops runs the daily sync here: the fallback stays quiet (also when an administrator has switched the job off)
    def ops_handles? = defined?(::GkOps::Scheduler) && ::GkOps::Scheduler.handles?(JOB_KEY)

    FEATURE = 'people.responsibilities'
    VACANT_INVARIANT = 'responsibility_vacant'

    # The daily job and the invariant on vacant responsibilities are in ops only while the function
    # people.responsibilities is on. Asked at boot (force) and then at most once a minute from a request
    # (DailyPatch), so a switch holds without a restart; the scheduler's thread reads the same registry. Only a
    # change touches ops' registries. The job's row and its runs stay in ops (P1).
    def ops_registrations!(force: false)
      now = Time.current
      return if !force && @ops_checked_at && now - @ops_checked_at < 60

      @ops_checked_at = now
      on = GkPeople.feature?(FEATURE)
      if defined?(::GkOps::Scheduler)
        jobs = ::GkOps::Scheduler.registry
        if on && !jobs.key?(JOB_KEY)
          # the one-line description where ops takes one
          more = ::GkOps::Scheduler.method(:register).parameters.any? { |_t, n| n == :description } ? { description: :text_gk_people_role_sync_job } : {}
          ::GkOps::Scheduler.register(JOB_KEY, name: :label_gk_people_role_sync, plugin: :gk_people, at: '00:05', **more) do |run|
            GkPeople::RoleSync.scheduled!(run)
          end
        elsif !on && jobs.key?(JOB_KEY)
          jobs.delete(JOB_KEY)
        end
      end
      if defined?(::GkOps::Invariants)
        invs = ::GkOps::Invariants.registry
        key = "gk_people.#{VACANT_INVARIANT}"
        if on && !invs.key?(key)
          ::GkOps::Invariants.register(:gk_people, VACANT_INVARIANT, label_key: :label_gk_people_inv_vacant, rows: -> { vacant_rows })
        elsif !on && invs.key?(key)
          invs.delete(key)
        end
      end
      nil
    rescue StandardError => e
      Rails.logger.warn("[gk_people] ops registrations: #{e.message}")
      nil
    end

    # The invariant's rows, asked by ops in its own job: every vacant responsibility by name, with the address of its
    # page. While the gate to GK GUI Stuff is closed (gate.rb) the vacancy is still reported, but the page is closed,
    # so the row is given without an address and ops draws the name alone
    def vacant_rows
      u = Rails.application.routes.url_helpers
      GkPeople::Gate.rows(GkPeople::Responsibilities.vacancies) { |r| u.gk_people_responsibility_path(r) }
    end

    # The job in ops: one run, with what it did as steps
    def scheduled!(ops_run)
      unless GkPeople.feature?(FEATURE) && enabled?
        ops_run.step(I18n.t(:text_gk_people_role_sync_off))
        return nil
      end
      r = run!(kind: 'scheduled')
      return nil unless r

      ops_run.step(I18n.t(:notice_gk_people_role_sync_run, added: r.added, removed: r.removed, deviations: r.deviations))
      ops_run.step(I18n.t(:text_gk_people_role_sync_no_account, count: r.no_account)) if r.no_account.positive?
      raise r.errors_text if r.errors_text.present?

      nil
    end

    # The fallback without ops: the daily run at the first request after midnight. Remembered in the process, so other
    # requests cost nothing.
    def daily_if_due
      today = ::Date.today
      return if @checked_on == today
      return if ops_handles?
      return unless GkPeople.feature?(FEATURE) && enabled?

      @checked_on = today
      run = ::GkPeopleRoleSyncRun.create!(kind: 'daily', run_on: today, started_at: Time.current)
      as_system { run!(kind: 'daily', run: run) }
    rescue ActiveRecord::RecordNotUnique
      nil # another request or process did it today
    rescue StandardError => e
      Rails.logger.warn("[gk_people] role_sync daily: #{e.message}")
    end

    def as_system
      prev = ::User.current
      ::User.current = ::User.anonymous
      yield
    ensure
      ::User.current = prev
    end

    # A membership role people gave was removed outside the sync: who and when (the sync sees it too, without who)
    def member_role_gone(member_role)
      return if running? || !ready?

      ::GkPeopleRoleGrant.active.where(member_role_id: member_role.id, removed_by_hand_at: nil).find_each do |g|
        by = ::User.current.logged? ? ::User.current.id : nil
        g.update_columns(removed_by_hand_at: Time.current, removed_by_id: by, member_role_id: nil)
        event(g, 'role_removed_by_hand', by: by && GkPeople::Refs.person(by)) # records' reference, never the name
      end
    rescue StandardError => e
      Rails.logger.warn("[gk_people] role_sync member_role_gone: #{e.message}")
    end

    # The grants behind a member's roles in a project (the project's member list)
    def grants_for_member(member)
      return [] unless ready? && member.user_id

      ::GkPeopleRoleGrant.active.where(user_id: member.user_id, project_id: member.project_id).includes(rule: :responsibility, role: []).to_a
    end

    module MemberRolePatch
      def self.prepended(base)
        base.after_destroy { GkPeople::RoleSync.member_role_gone(self) }
      end
    end

    # The daily run: after core's user_setup (and people's own), never in Se som, never failing the request
    module DailyPatch
      private

      def user_setup
        r = super
        GkPeople::RoleSync.ops_registrations! # At most once a minute
        unless defined?(GkPeople::SeeAs) && GkPeople::SeeAs.state
          GkPeople::RoleSync.daily_if_due
        end
        r
      end
    end

    class Hooks < Redmine::Hook::ViewListener
      include GkPeople::Gate::Listener # silent without GK GUI Stuff (gate.rb)

      # The project's member list: which roles come from a responsibility, with a link
      def view_projects_settings_members_table_header(_context = {})
        return '' unless GkPeople::RoleSync.ready? && GkPeople.feature?(FEATURE)

        content_tag('th', l(:label_gk_people_from_responsibility))
      end

      def view_projects_settings_members_table_row(context = {})
        return '' unless GkPeople::RoleSync.ready? && GkPeople.feature?(FEATURE)

        grants = GkPeople::RoleSync.grants_for_member(context[:member])
        links = grants.map do |g|
          r = g.rule&.responsibility
          next unless r

          text = "#{g.role&.name}: #{r.name}#{g.via == 'deputy' ? " (#{l(:label_gk_people_deputy).downcase})" : ''}"
          s = link_to(text, gk_people_responsibility_path(r))
          g.deviating? ? safe_join([s, ' ', content_tag('span', l(:label_gk_people_deviation), class: 'badge badge-private gk-people-badge gk-people-lacking')]) : s
        end.compact
        content_tag('td', safe_join(links, '<br>'.html_safe), class: 'gk-people-from-resp')
      end
    end
  end
end
