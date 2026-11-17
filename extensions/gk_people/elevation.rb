# frozen_string_literal: true

module GkPeople
  # elevation (plugins/people): admin as a layer on one's own account. An administrator works as herself and steps
  # up when something needs admin: the password again, a reason if she wants, and a time that is extended while she
  # works and falls away when she stops, steps down or logs out. Everything she changes meanwhile is kept with the
  # elevation, so it can always be said who did what as Administration.
  #
  # How: in a web request User#admin? answers the account's admin flag only while the account is stepped up in this
  # session; otherwise false, and core's own barriers (require_admin, menus, filters) do the rest. A page that needs
  # admin sends the administrator to the step-up form instead of a 403.
  # Outside web requests (jobs, console, migrations) and, until admin_api keys exist, in API requests, admin? is the
  # flag as in core. Only the account making the request is affected: another administrator shown on the page (in the
  # users list, as a recipient) keeps her flag.
  #
  # Safe by construction
  # * it is a setting, and it holds only while an active administrator account belongs to a person (only such an
  #   account may step up) and at least one reserve account is chosen
  # * reserve accounts (GkPeople::Reserve): personal ones the plugin makes for the administrators ticked in the
  #   settings, and a shared one if the organization chose one; never asked to step up, so there is always a way in
  #   if this layer has a bug; locked unless opened in control/reserve.txt; every session of theirs is kept as an
  #   elevation (method reserve, the owner's person) with what was changed, and shown under Upphöjningar;
  # * fail open: any error in the layer answers admin? with the flag, as in core, and is logged; a bug can never
  #   lock administrators out;
  # * off without the web: GK_ELEVATION=off in the environment, or the word off first in the file
  #   control/elevation.txt beside the instance's INSTANCE.yml (GK_INSTANCE_FILE), switches the layer off at the next
  #   request; on (or no file) leaves it to the setting. A word in a file, like restart.request, so that it can be
  #   switched back without deleting anything.
  # Switched off, or the plugin removed, every admin flag is full admin again as in core. Stepping up also counts as
  # core's sudo mode (7.0), so the password is asked once.
  module Elevation
    SESSION_KEY = :gk_people_elevation_id
    THREAD_KEY = :gk_people_elevation
    KINDS = %w[elevation_started elevation_ended elevation_failed elevation_reserve_used elevation_gate_open].freeze
    # The method of an elevation kept because the gate to GK GUI Stuff was closed (setup_gate!)
    GATE_METHOD = 'gate'
    # How an elevation ends when the gate changes under it while its window is still open: one kept while the gate
    # was closed ends when the gate opens, and a step up ends when the gate closes. One whose window has run out
    # ended because the time ran out, whatever the gate did afterwards
    END_GATE_OPENED = 'gate_opened'
    END_GATE_CLOSED = 'gate_closed'
    # Pages that never need stepping up: the step-up itself, logging in and out, the account's own page
    FREE = %w[gk_people_elevations account].freeze

    module_function

    def settings = (Setting.plugin_gk_people rescue {}) || {}
    def enabled? = settings['elevation_enabled'].to_s == '1'
    def minutes = Window.minutes(settings['elevation_minutes'], 15)
    def max_minutes = [Window.minutes(settings['elevation_max_minutes'], 120), minutes].max

    def real_admin?(user) = user.is_a?(::User) && user.logged? && user.read_attribute(:admin) == true

    # Reserve accounts (GkPeople::Reserve): personal ones made by the plugin, and the shared one if chosen
    def reserve?(user) = Reserve.reserve?(user)

    # The switch outside the web: GK_ELEVATION=off, or off first in control/elevation.txt beside INSTANCE.yml
    def switched_off?
      return true if ENV['GK_ELEVATION'].to_s.strip.casecmp?('off')

      f = ENV['GK_INSTANCE_FILE'].to_s
      return false if f.empty?

      path = File.join(File.dirname(f), 'control', 'elevation.txt')
      File.exist?(path) && Switch.off?(File.read(path, 200).to_s.force_encoding('UTF-8').scrub)
    rescue StandardError
      false
    end

    # Why the layer is not in force although switched on (nil when it is, or when it is off): for the settings page
    def held_back
      return nil unless enabled?
      return :switched_off if switched_off?
      return :no_reserve if Reserve.user_ids.empty?
      return :no_holder unless ::User.active.where(admin: true, type: 'User').where(id: ::GkPeoplePerson.where.not(user_id: nil).select(:user_id)).exists?

      nil
    rescue StandardError
      :error
    end

    # Is the layer in force at all: switched on, no switch outside the web, a reserve account, an administrator with a person
    def active? = enabled? && held_back.nil?

    # Fail open: an error in the layer gives core's answer and is logged, never a locked door
    def guard(fallback)
      yield
    rescue StandardError => e
      Rails.logger.error("[gk_people] elevation failed open: #{e.class}: #{e.message}")
      clear!
      fallback
    end

    # The request's state, set at user_setup and cleared when the request ends: nil outside web requests
    def state = Thread.current[THREAD_KEY]
    def clear! = (Thread.current[THREAD_KEY] = nil)

    def setup!(controller)
      clear!
      user = ::User.current
      return unless real_admin?(user) && !controller.send(:api_request?) && active?
      return setup_reserve!(controller, user) if reserve?(user)
      return setup_gate!(controller, user) unless GkPeople.gui?

      e = nil
      id = controller.session[SESSION_KEY]
      if id
        e = ::GkPeopleElevation.find_by(id: id, user_id: user.id, ended_at: nil)
        # one kept while the gate was closed is no step up: nobody gave a password for it. It ends because the gate
        # opened; one whose window has run out, because the time ran out
        if e && (!e.open? || e.auth_method == GATE_METHOD)
          e.end!(e.open? ? END_GATE_OPENED : 'expired')
          e = nil
        end
        controller.session.delete(SESSION_KEY) unless e
      end
      Thread.current[THREAD_KEY] = { user_id: user.id, elevation: e, person: GkPeople.person_for(user) }
    end

    # A reserve account is never asked to step up: its session is an elevation of its own (method reserve), opened at
    # its first request and kept like any other, so that what it changes is traced
    def setup_reserve!(controller, user)
      id = controller.session[SESSION_KEY]
      e = id && ::GkPeopleElevation.find_by(id: id, user_id: user.id, ended_at: nil, auth_method: 'reserve')
      if e && !e.open?
        e.end!('expired')
        e = nil
      end
      unless e
        now = Time.current
        e = ::GkPeopleElevation.create!(user_id: user.id, person_id: Reserve.owner_person(user)&.id, auth_method: 'reserve', started_at: now,
                                      last_activity_at: now, expires_at: Window.expires_at(now, now, minutes, max_minutes),
                                      ip: controller.request.remote_ip.to_s[0, 60])
        controller.session[SESSION_KEY] = e.id
        GkPeople.write(user, 'elevation_reserve_used', { elevation_id: e.id, path: controller.request.path.to_s[0, 200] })
      end
      Thread.current[THREAD_KEY] = { user_id: user.id, elevation: e, person: Reserve.owner_person(user), reserve: true }
    end

    # The gate to GK GUI Stuff is closed (gate.rb) where the layer would have held: the step-up form cannot be drawn,
    # so the layer still opens, as when it is off, and every admin flag is full admin. The opening is kept as an
    # elevation of its own (method gate), after the reserve account's pattern: opened at the session's first request,
    # found again through the session and renewed when its window has run out, so that what is changed under it is
    # traced (after_request!). An event on the account says it once per elevation, with the page asked for (written
    # when the row is made, as for a reserve account: an event that could not be written then is not written later); why the
    # gate was closed is in the event's details, in the field GK Records marks every event with that is written
    # while the gate is closed. The state counts as stepped up, so admin? answers the flag and nobody is sent to the
    # closed step-up page. A fault here is caught by guard like any other: the layer opens and logs.
    # A request whose account did not come out of the session (a feed read with its key, a file fetched with an API
    # key: no cookie, so every request is a session of its own) has no session to find the elevation through. It
    # goes under the account's own open gate elevation, whichever request opened it, and a new one is kept only when
    # there is none: one row and one event for each window, not for each request. Nothing is put in its session.
    def setup_gate!(controller, user)
      in_session = controller.session[:user_id] == user.id
      id = in_session ? controller.session[SESSION_KEY] : nil
      e = id && ::GkPeopleElevation.find_by(id: id, user_id: user.id, ended_at: nil)
      # its window has run out (the time ran out), or it is a step up from before the gate closed (the gate closed):
      # ended, and a new one is kept
      if e && (!e.open? || e.auth_method != GATE_METHOD)
        e.end!(e.open? ? END_GATE_CLOSED : 'expired')
        e = nil
      end
      e ||= open_gate_elevation(user) unless in_session
      person = GkPeople.person_for(user)
      unless e
        now = Time.current
        e = ::GkPeopleElevation.create!(user_id: user.id, person_id: person&.id, auth_method: GATE_METHOD, started_at: now,
                                      last_activity_at: now, expires_at: Window.expires_at(now, now, minutes, max_minutes),
                                      ip: controller.request.remote_ip.to_s[0, 60])
        controller.session[SESSION_KEY] = e.id if in_session
        GkPeople.write(user, 'elevation_gate_open', { elevation_id: e.id, path: controller.request.path.to_s[0, 200] }.merge(gate_detail))
      end
      Thread.current[THREAD_KEY] = { user_id: user.id, elevation: e, person: person, gate: true }
    end

    # The account's newest gate elevation whose window is still open, for a request without a session of its own
    def open_gate_elevation(user)
      ::GkPeopleElevation.where(user_id: user.id, auth_method: GATE_METHOD, ended_at: nil, expires_at: Time.current..)
                         .order(id: :desc).first
    end

    # Why the gate was closed, under the field GK Records marks an event with that is written while the gate is
    # closed (GkRecords::Gate::DETAIL); nothing with a GK Records that has no such field
    def gate_detail
      closed = GkPeople.gui_closed
      closed && defined?(::GkRecords::Gate::DETAIL) ? { ::GkRecords::Gate::DETAIL => closed.to_s } : {}
    end

    # Does the layer decide admin? for this account now: a web request by this very account while the layer holds
    def governs?(user) = (st = state) && st[:user_id] == user.id
    def current = state&.dig(:elevation)
    def elevated? = !current.nil?
    def reserve_session? = state&.dig(:reserve) == true

    # May the one asking step up (an administrator with a person, not stepped up already)
    def may_step_up?(user = ::User.current) = governs?(user) && !elevated? && !state[:person].nil?
    def lacks_person?(user = ::User.current) = governs?(user) && state[:person].nil?

    # Reasons to offer on the step-up form, since the same ones come back: her own, the most recent first, then the
    # ones other administrators use most; each once (any case), at most so many
    def earlier_reasons(user, limit: 8)
      own = ::GkPeopleElevation.where(user_id: user.id).where.not(reason: [nil, '']).order(started_at: :desc).limit(100).pluck(:reason)
      common = ::GkPeopleElevation.where.not(user_id: user.id).where.not(reason: [nil, '']).group(:reason).order(Arel.sql('COUNT(*) DESC')).limit(50).pluck(:reason)
      Reasons.pick(own, common, limit)
    rescue StandardError
      []
    end

    # Window: extended by every request while stepped up, never past the maximum from the start
    def extend!(e, now = Time.current)
      e.update_columns(last_activity_at: now, expires_at: Window.expires_at(e.started_at, now, minutes, max_minutes))
    end

    # After a request: keep the window open and keep what was changed
    def after_request!(controller)
      e = current
      return unless e

      e.reload
      return unless e.ended_at.nil?

      extend!(e)
      return if controller.request.get? || controller.request.head? || FREE.include?(controller.controller_name)

      ::GkPeopleElevationAction.create(elevation_id: e.id, controller: controller.controller_name.to_s[0, 100],
                                     action: controller.action_name.to_s[0, 100], http_method: controller.request.request_method,
                                     path: controller.request.path.to_s[0, 500], target_id: controller.params[:id].to_s[0, 100].presence,
                                     status: controller.response.status, at: Time.current)
    rescue StandardError => ex
      Rails.logger.warn("[gk_people] elevation action not kept: #{ex.class}: #{ex.message}")
    end

    # Wrong passwords at stepping up: counted per account in Rails.cache (no table), and after five in a row each
    # further try waits 30, 60, then at most 120 seconds (Backoff). A right password clears the count. Never a
    # locked door: reserve accounts never step up and are never held back, the wait is at most two minutes, and a
    # cache that fails holds no one back (fail open, like the rest of the layer).
    FAILURES_KEEP = 3600
    def failures_key(user) = "gk_people/elevation_failures/#{user.id}"

    def failures(user)
      v = Rails.cache.read(failures_key(user))
      v.is_a?(Hash) ? v : {}
    rescue StandardError
      {}
    end

    # Whole seconds before this account may try a password again (0: now)
    def wait_seconds(user, now = Time.current)
      return 0 if reserve?(user)

      f = failures(user)
      Backoff.remaining(f['count'], f['at'], now)
    rescue StandardError => e
      Rails.logger.warn("[gk_people] elevation wait not read: #{e.class}: #{e.message}")
      0
    end

    def note_failure!(user, now = Time.current)
      n = failures(user)['count'].to_i + 1
      Rails.cache.write(failures_key(user), { 'count' => n, 'at' => now.to_f }, expires_in: FAILURES_KEEP)
      n
    rescue StandardError => e
      Rails.logger.warn("[gk_people] elevation failure not counted: #{e.class}: #{e.message}")
      nil
    end

    def clear_failures!(user)
      Rails.cache.delete(failures_key(user))
    rescue StandardError
      nil
    end

    # A try during the wait: refused without looking at the password, and kept as an event like a wrong one
    def refuse_waiting!(user, seconds)
      GkPeople.write(user, 'elevation_failed', { how: 'waiting', seconds: seconds, failures: failures(user)['count'].to_i })
    rescue StandardError => e
      Rails.logger.warn("[gk_people] elevation wait not kept: #{e.class}: #{e.message}")
    end

    # Step up: the password again (core's own check, LDAP too), then a window; counts as core's sudo mode. The session
    # gets a new id (its contents kept, so nobody is logged out): an id known from before stepping up is worth nothing.
    def step_up!(controller, password, reason)
      user = ::User.current
      unless user.check_password?(password.to_s)
        n = note_failure!(user)
        GkPeople.write(user, 'elevation_failed', { how: 'password', failures: n, wait: Backoff.delay(n) })
        return nil
      end

      clear_failures!(user)
      renew_session!(controller)
      now = Time.current
      e = ::GkPeopleElevation.create!(user_id: user.id, person_id: state&.dig(:person)&.id, auth_method: 'password', reason: reason.to_s.strip.presence,
                                    started_at: now, last_activity_at: now, expires_at: Window.expires_at(now, now, minutes, max_minutes),
                                    ip: controller.request.remote_ip.to_s[0, 60])
      controller.session[SESSION_KEY] = e.id
      controller.session[:sudo_timestamp] = now.to_i
      Thread.current[THREAD_KEY][:elevation] = e if state
      # The reason goes with the event as its reason, no longer in the details; records still reads details['reason']
      # back for the older events (GkRecordsEvent#details_reason), and people reads it from nowhere
      GkPeople.write(user, 'elevation_started', { elevation_id: e.id, until: e.expires_at }, reason: e.reason)
      e
    end

    # A new session id at the end of this request with the same contents (Rack's renew option; Rails 7.2 and 8.1, the
    # cookie store as in Redmine): unlike reset_session nothing has to be put back
    def renew_session!(controller)
      controller.request.session_options[:renew] = true
    rescue StandardError => e
      Rails.logger.warn("[gk_people] session not renewed at step-up: #{e.class}: #{e.message}")
    end

    def step_down!(controller, reason = 'stepped_down')
      SeeAs.stop!(controller, 'elevation_ended') if controller.session[SeeAs::SESSION_KEY]
      e = current || (id = controller.session[SESSION_KEY]) && ::GkPeopleElevation.find_by(id: id)
      controller.session.delete(SESSION_KEY)
      e&.end!(reason)
      state[:elevation] = nil if state
      e
    end

    # The core patches: User#admin? and ApplicationController (user_setup, the end of every request, require_admin,
    # deny_access, logout)
    module UserPatch
      def admin?
        real = super
        return real unless real

        Elevation.guard(real) { Elevation.governs?(self) ? Elevation.elevated? : real }
      end
    end

    module ControllerPatch
      private

      def process_action(*args)
        super
      ensure
        Elevation.after_request!(self) if Elevation.state
        Elevation.clear!
      end

      def user_setup
        Elevation.guard(nil) { Reserve.tick! }
        super
        Elevation.guard(nil) { Elevation.setup!(self) }
      end

      def require_admin
        return send_to_step_up if Elevation.guard(false) { Elevation.may_step_up? && !User.current.admin? }

        super
      end

      def deny_access
        return send_to_step_up if Elevation.guard(false) { Elevation.may_step_up? }

        super
      end

      def logout_user
        Elevation.guard(nil) { Elevation.step_down!(self, 'logout') if Elevation.state && session[Elevation::SESSION_KEY] }
        super
      end

      # A page asked for admin: the step-up form, back to the page afterwards (a GET); anything else is refused
      def send_to_step_up
        if request.get? && !api_request? && !request.xhr?
          redirect_to gk_people_elevate_path(back_url: request.original_url)
        else
          render_403(message: :notice_gk_people_step_up_first)
        end
        false
      end
    end

    # The state in the top menu (stepped up, the reserve account, an administrator without a person) with gui_stuff's
    # ribbon; no bar over the page. The rows in core's account menu are GkPeople::StateMenu's.
    class Hooks < Redmine::Hook::ViewListener
      include GkPeople::Gate::Listener # silent without GK GUI Stuff (gate.rb)
      def view_layouts_base_html_head(_context = {})
        return '' unless Elevation.governs?(::User.current)

        stylesheet_link_tag('gk_people', plugin: 'gk_people') + javascript_include_tag('gk_people_elevation', plugin: 'gk_people') +
          javascript_include_tag('gk_people_topmenu', plugin: 'gk_people')
      rescue StandardError => e
        Rails.logger.error("[gk_people] elevation head not added: #{e.class}: #{e.message}")
        ''
      end

      def view_layouts_base_body_top(context = {})
        v = context[:hook_caller]
        return '' unless v && Elevation.governs?(::User.current)

        v.render(partial: 'gk_people_elevations/menu', locals: { elevation: Elevation.current, lacks_person: Elevation.lacks_person?,
                                                              reserve: Elevation.reserve_session? })
      rescue StandardError => e
        Rails.logger.error("[gk_people] elevation state not shown: #{e.class}: #{e.message}")
        ''
      end
    end
  end
end
