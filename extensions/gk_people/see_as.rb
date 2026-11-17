# frozen_string_literal: true

module GkPeople
  # Se som: an administrator, stepped up, looks at the pages as a person, a group or a role in a project would see
  # them. Only a passive look: nothing is ever done in the name of the one looked at.
  #
  # How
  # * Person: for the request User.current is the person's account, so core counts the rights itself and the page is
  #   exactly what she sees. Group or role: an account that is never saved (no id), whose memberships are in memory
  #   (the group's memberships, or the role in the one project), so that core's allowed_to? and visibility count as
  #   usual. Either way the account looked as is never administrator, never asked to change its password or turn on
  #   two-factor, and its language is used (she sees her language).
  # * Read only twice over: everything but GET and HEAD is refused before the page runs, and every request runs in a
  #   database transaction that is rolled back, so that nothing a page writes while it is read (last login, a query
  #   kept, a key generated) is kept. No mail is delivered under Se som (ActionMailer is stopped for the request).
  #   Pages that show secrets (API and RSS keys, two-factor) are refused outright.
  # * Only while stepped up, never for a reserve account (it has no person); ends when the elevation ends.
  # * Traced: a row in gk_people_see_as_sessions per time, written outside the rolled-back request, events on the
  #   administrator (see_as_started, see_as_ended) and on the person looked at (see_as_viewed, in her extract).
  # * The pages of elevation, of Se som itself and of logging in and out are never looked at as someone else, so that
  #   one can always stop.
  module SeeAs
    SESSION_KEY = :gk_people_see_as_id
    THREAD_KEY = :gk_people_see_as
    WRAPPED_KEY = :gk_people_see_as_wrapped
    KINDS = %w[see_as_started see_as_ended see_as_viewed].freeze
    # Never looked at as someone else: these run as the administrator
    FREE = %w[gk_people_see_as gk_people_elevations account].freeze

    module_function

    def state = Thread.current[THREAD_KEY]
    def clear! = (Thread.current[THREAD_KEY] = nil)
    def active? = GkPeople.gui? && !state.nil?
    def record = state&.dig(:record)
    def viewer = state&.dig(:viewer)
    def viewer?(user) = active? && user.equal?(viewer)

    def table? = (::GkPeopleSeeAs.table_exists? rescue false)

    # The open Se som of this session, if any: open, under the elevation of this session, not ended
    def open_for(controller)
      id = controller.session[SESSION_KEY]
      return nil unless id && table?

      r = ::GkPeopleSeeAs.find_by(id: id, ended_at: nil)
      e = r && ::GkPeopleElevation.find_by(id: r.elevation_id)
      if r.nil? || e.nil? || !e.open? || e.id != controller.session[Elevation::SESSION_KEY]
        r&.end!('elevation_ended')
        controller.session.delete(SESSION_KEY)
        return nil
      end
      r
    end

    # Does this request run as someone else (decided before the request runs, so that it can be rolled back)
    def applies?(controller)
      return false if FREE.include?(controller.controller_name) || controller.send(:api_request?)

      !open_for(controller).nil?
    rescue StandardError => e
      Rails.logger.error("[gk_people] see_as not applied: #{e.class}: #{e.message}")
      false
    end

    # May the one asking start Se som: stepped up as herself (not a reserve account), the table there
    def may_start?(user = ::User.current)
      table? && Elevation.governs?(user) && Elevation.elevated? && !Elevation.reserve_session? && !active?
    end

    # May Se som… be offered in the menus: stepped up, or able to step up (the choice then says to step up first)
    def may_offer?(user = ::User.current)
      table? && Elevation.governs?(user) && !Elevation.reserve_session? && !active? && (Elevation.elevated? || Elevation.may_step_up?(user))
    end

    # After user_setup: User.current becomes the one looked as
    def setup!(controller)
      r = open_for(controller)
      return unless r

      v = viewer_for(r)
      return unless v

      Thread.current[THREAD_KEY] = { record: r, viewer: v, real: ::User.current, elevation_id: r.elevation_id }
      ::User.current = v
    end

    # The account to look as
    def viewer_for(r)
      v = case r.kind
          when 'person'
            ::User.active.find_by(id: r.target_user_id, type: 'User') # a fresh object, never the administrator's
          when 'group'
            g = ::Group.givable.find_by(id: r.target_group_id)
            g && synthetic(-> { g.lastname }).extend(GroupViewer).tap { |x| x.gk_people_group = g }
          when 'role'
            role = ::Role.givable.find_by(id: r.role_id)
            role && synthetic(-> { role.name }).extend(RoleViewer).tap { |x| x.gk_people_role_in(role, r.project) }
          end
      v&.extend(ViewerFlags)
    end

    def synthetic(name)
      u = ::User.new(language: ::User.current.language, mail_notification: 'none')
      u.firstname = (name.respond_to?(:call) ? name.call : name).to_s[0, 30]
      u.lastname = '-'
      u.login = ''
      u.status = ::Principal::STATUS_ACTIVE
      u.id = 0 # never saved; 0 matches no row, so SQL that names the user ("me", own issues) works and finds nothing
      u.extend(SyntheticName)
      u.gk_people_label = name
      u
    end

    # Start: a row, the session key, the events; the page she is on is shown again as the one looked as
    def start!(controller, kind:, target_user: nil, target_group: nil, role: nil, project: nil, place: nil, reason: nil)
      admin = ::User.current
      e = Elevation.current
      return nil unless e && may_start?(admin)

      r = ::GkPeopleSeeAs.create!(elevation_id: e.id, user_id: admin.id, person_id: GkPeople.person_for(admin)&.id, kind: kind,
                                target_user_id: target_user&.id, target_group_id: target_group&.id, role_id: role&.id,
                                project_id: project&.id, place: place.to_s[0, 500].presence, reason: reason.to_s.strip.presence,
                                started_at: Time.current)
      controller.session[SESSION_KEY] = r.id
      # a person or a group looked as is records' reference, never a name or a login (a role in a project stays its label)
      as = case kind.to_s
           when 'person' then GkPeople::Refs.person(target_user)
           when 'group' then GkPeople::Refs.person(target_group)
           else r.target_label
           end
      # The reason goes with the events as their reason, no longer in the details; records still reads details['reason']
      # back for the older events (GkRecordsEvent#details_reason), and people reads it from nowhere
      GkPeople.write(admin, 'see_as_started', { see_as_id: r.id, elevation_id: e.id, kind: kind, as: as, place: r.place }, reason: r.reason)
      GkPeople.write(target_user, 'see_as_viewed', { see_as_id: r.id, by: GkPeople::Refs.person(admin), place: r.place }, reason: r.reason) if target_user
      r
    end

    def stop!(controller, reason = 'stopped')
      id = controller.session.delete(SESSION_KEY)
      r = id && table? ? ::GkPeopleSeeAs.find_by(id: id) : nil
      r&.end!(reason)
      r
    end

    # After the rolled-back request: count the page and keep the elevation open while she looks (outside the
    # transaction, so that it is kept)
    def after_request!(controller, st)
      return unless st

      ::GkPeopleSeeAs.where(id: st[:record].id).update_all(['pages = pages + 1, last_path = ?', controller.request.path.to_s[0, 500]])
      e = ::GkPeopleElevation.find_by(id: st[:elevation_id])
      Elevation.extend!(e) if e&.open?
    rescue StandardError => ex
      Rails.logger.warn("[gk_people] see_as page not counted: #{ex.class}: #{ex.message}")
    end

    # What the state's box says about the place: nil, :not_member, :role_elsewhere or :role_missing (SeeAsPlace in core)
    def place_notice(project)
      st = state
      return nil unless st && project.is_a?(::Project)

      r = st[:record]
      case r.kind
      when 'person'
        SeeAsPlace.notice(kind: 'person', here: project.id, member_here: ::Member.where(project_id: project.id, user_id: r.target_user_id).exists?)
      when 'group'
        SeeAsPlace.notice(kind: 'group', here: project.id, member_here: ::Member.where(project_id: project.id, user_id: r.target_group_id).exists?)
      else
        SeeAsPlace.notice(kind: 'role', here: project.id, role_project: r.project_id, role_used: role_used?(r.role_id, r.project_id))
      end
    end

    def role_used?(role_id, project_id)
      ::MemberRole.joins(:member).where(role_id: role_id, members: { project_id: project_id }).exists?
    end

    # Where she is: the project and issue of a path in this Redmine (for the choices that belong to the place)
    def place_of(path)
      path = path.to_s.split('?').first.to_s
      root = Redmine::Utils.relative_url_root.to_s
      path = path.delete_prefix(root) if root.present? && path.start_with?(root)
      prm = Rails.application.routes.recognize_path(path, method: :get) rescue {}
      issue = prm[:controller] == 'issues' && prm[:id].to_s =~ /\A\d+\z/ ? ::Issue.find_by(id: prm[:id]) : nil
      pid = prm[:project_id] || (prm[:controller] == 'projects' ? prm[:id] : nil)
      project = issue&.project || (pid && (::Project.find_by(identifier: pid.to_s) || ::Project.find_by(id: pid.to_s.to_i)))
      { project: project, issue: issue }
    end

    # The choices for a place: those seen in the issue, the project's people, groups and roles, the roles not in it
    def choices(place, admin)
      out = { issue: [], users: [], groups: [], roles: [], roles_missing: [] }
      skip = [admin.id] + (Reserve.user_ids rescue [])
      if (i = place[:issue])
        ([i.author, i.assigned_to] + i.watcher_users.to_a).compact.uniq.each do |p|
          next if skip.include?(p.id) || !p.active?

          out[:issue] << p if p.is_a?(::User) || p.is_a?(::Group)
        end
      end
      if (pr = place[:project])
        members = ::Member.where(project_id: pr.id).includes(:principal, :roles).to_a
        members.map(&:principal).compact.each do |p|
          next if skip.include?(p.id) || !p.active?

          out[:users] << p if p.is_a?(::User) && p.type == 'User'
          out[:groups] << p if p.instance_of?(::Group)
        end
        used = members.flat_map(&:roles).uniq.reject(&:builtin?)
        out[:roles] = used.sort_by(&:position)
        out[:roles_missing] = ::Role.givable.sorted.to_a - used
      end
      out[:users].sort_by!(&:name)
      out[:groups].sort_by!(&:lastname)
      out
    end

    # Search among all: active people with an account and groups, never reserve accounts or oneself
    def search(q, admin, limit: 20)
      return [] if q.to_s.strip.length < 2

      skip = [admin.id] + (Reserve.user_ids rescue [])
      ::Principal.active.where(type: %w[User Group]).like(q.to_s.strip).where.not(id: skip).sorted.limit(limit).to_a
    end

    # The mail the one looked as would get about an issue, rendered and never delivered: [mail, would_get]
    # would_get: true or false for a person, nil for a group or role (it depends on the person's settings)
    def mail_preview(issue, v, r)
      journal = issue.journals.reorder(id: :desc).detect { |j| j.notes.present? || j.details.any? }
      msg = journal ? ::Mailer.issue_edit(v, journal) : ::Mailer.issue_add(v, issue)
      mail = msg.message
      would = if r.kind == 'person'
                pool = journal ? (journal.notified_users | journal.notified_watchers | journal.notified_mentions) : (issue.notified_users | issue.notified_watchers | issue.notified_mentions)
                pool.map(&:id).include?(v.id)
              end
      [mail, would]
    end

    # The body of a mail as HTML to show (the HTML part, else the text part as preformatted text)
    def mail_html(mail)
      part = mail.html_part || (mail.content_type.to_s.start_with?('text/html') ? mail : nil)
      return part.body.decoded.to_s.force_encoding('UTF-8') if part

      text = (mail.text_part || mail).body.decoded.to_s.force_encoding('UTF-8')
      "<pre style=\"white-space: pre-wrap; font-family: inherit;\">#{ERB::Util.html_escape(text)}</pre>" # gk-u U1: the mail shows in a sandboxed frame that loads no stylesheet
    end

    # The account looked as: never administrator, never sent to change its password or turn on two-factor
    module ViewerFlags
      def admin? = false
      def must_change_password? = false
      def must_activate_twofa? = false
      def gk_people_viewer? = true
      def update_last_login_on! = nil
      # Never the keys of the one looked as (feed links on the pages carry the current user's key), and never made
      NO_KEY = 'see-as'
      def rss_key = NO_KEY
      def atom_key = NO_KEY
      def api_key = NO_KEY
    end

    module SyntheticName
      attr_accessor :gk_people_label

      # The name in the language of the page (a role's name can be translated), so asked for each time
      def name(*) = (gk_people_label.respond_to?(:call) ? gk_people_label.call : gk_people_label).to_s
      def to_s = name
      def mails = []
      # Links to the account (the layout's "Inloggad som", avatars) go to /users/current, which Se som refuses for a
      # group or role (it has no page)
      def to_param = 'current'
      def gk_people_synthetic? = true
    end

    # A group's rights: its memberships, and for the rest what a non-member gets
    module GroupViewer
      attr_reader :gk_people_group

      def gk_people_group=(g)
        @gk_people_group = g
        @gk_people_members = g.memberships.includes(:roles, :project).to_a
      end

      def groups = ::Group.where(id: @gk_people_group.id)
      def group_ids = [@gk_people_group.id]
      def memberships = ::Member.where(id: @gk_people_members.map(&:id))
      def project_ids = @gk_people_members.map(&:project_id)

      def membership(project)
        pid = project.is_a?(::Project) ? project.id : project
        @gk_people_members.detect { |m| m.project_id == pid.to_i }
      end

      def roles
        ids = @gk_people_members.flat_map { |m| m.roles.map(&:id) }
        ids.any? ? ::Role.where(id: ids.uniq) : super
      end

      def project_ids_by_role
        return @gk_people_ids_by_role if @gk_people_ids_by_role

        own = project_ids
        result = Hash.new([])
        super.each { |role, ids| rest = ids - own; result[role] = rest if rest.any? }
        @gk_people_members.each do |m|
          next if m.project.nil? || m.project.archived?

          m.roles.each { |role| result[role] = (result[role] + [m.project_id]).uniq }
        end
        @gk_people_ids_by_role = result
      end
    end

    # A role in one project: that role there, and what a non-member gets everywhere else. A role nobody has in the
    # project is not made up there: the project is then seen as by a non-member, and the state's box says so.
    module RoleViewer
      def gk_people_role_in(role, project)
        @gk_people_role = role
        @gk_people_project = project
        @gk_people_applies = project && SeeAs.role_used?(role.id, project.id)
        @gk_people_member = nil
        return unless @gk_people_applies

        m = ::Member.new(project: project)
        rid = role.id
        m.define_singleton_method(:roles) { ::Role.where(id: rid) }
        @gk_people_member = m
      end

      def project_ids = @gk_people_applies ? [@gk_people_project.id] : []

      def membership(project)
        pid = project.is_a?(::Project) ? project.id : project
        @gk_people_member if @gk_people_applies && pid.to_i == @gk_people_project.id
      end

      def roles
        @gk_people_applies ? ::Role.where(id: @gk_people_role.id) : super
      end

      def project_ids_by_role
        return @gk_people_ids_by_role if @gk_people_ids_by_role

        result = Hash.new([])
        super.each { |role, ids| rest = ids - project_ids; result[role] = rest if rest.any? }
        result[@gk_people_role] = (result[@gk_people_role] + [@gk_people_project.id]).uniq if @gk_people_applies
        @gk_people_ids_by_role = result
      end
    end

    # The request: refused if it would write, run in a transaction that is rolled back, no mail delivered
    module ControllerPatch
      private

      def process_action(*args)
        return super unless SeeAs.applies?(self)

        result = nil
        st = nil
        begin
          Thread.current[SeeAs::WRAPPED_KEY] = true
          ActiveRecord::Base.transaction(requires_new: true) do
            result = super
            st = SeeAs.state
            raise ActiveRecord::Rollback
          end
        ensure
          SeeAs.clear!
          Thread.current[SeeAs::WRAPPED_KEY] = nil
        end
        SeeAs.after_request!(self, st)
        result
      end

      # A request wrapped for Se som that could not be set up is refused, never run as the administrator unseen
      def user_setup
        super
        if Thread.current[SeeAs::WRAPPED_KEY]
          begin
            SeeAs.setup!(self)
          rescue StandardError => e
            Rails.logger.error("[gk_people] see_as not set up: #{e.class}: #{e.message}")
            SeeAs.clear!
          end
          return render_403(message: :notice_gk_people_see_as_failed) unless SeeAs.active?
        end
        return unless SeeAs.active?

        if !(request.get? || request.head?)
          render_403(message: :notice_gk_people_see_as_read_only)
        elsif SeeAsPlace.blocked?(controller_name, action_name)
          render_403(message: :notice_gk_people_see_as_blocked)
        elsif controller_name == 'users' && SeeAs.viewer.respond_to?(:gk_people_synthetic?) && params[:id].to_s == 'current'
          render_403(message: :notice_gk_people_see_as_no_page)
        end
      end

      def logout_user
        Elevation.guard(nil) { SeeAs.stop!(self, 'logout') if session[SeeAs::SESSION_KEY] }
        super
      end
    end

    # No mail is delivered while looking as someone else
    module DeliveryGuard
      def deliver_now(*) = SeeAs.active? ? nil : super
      def deliver_later(*) = SeeAs.active? ? nil : super
      def deliver_now!(*) = SeeAs.active? ? nil : super
      def deliver_later!(*) = SeeAs.active? ? nil : super
    end

    # The state in the top menu while looking as someone else (in place of the elevation's), with the ribbon and the
    # frame round the page; no bar over the page. The script for the choice wherever Se som… is offered.
    class Hooks < Redmine::Hook::ViewListener
      include GkPeople::Gate::Listener # silent without GK GUI Stuff (gate.rb)
      def view_layouts_base_html_head(_context = {})
        return '' unless SeeAs.active? || SeeAs.may_offer?

        tags = stylesheet_link_tag('gk_people', plugin: 'gk_people') + javascript_include_tag('gk_people_see_as', plugin: 'gk_people')
        SeeAs.active? ? tags + javascript_include_tag('gk_people_topmenu', plugin: 'gk_people') : tags
      rescue StandardError => e
        Rails.logger.error("[gk_people] see_as head not added: #{e.class}: #{e.message}")
        ''
      end

      def view_layouts_base_body_top(context = {})
        v = context[:hook_caller]
        return '' unless v && SeeAs.active?

        c = context[:controller]
        # the project of the page, also on a refusal (core's 403 forgets it): that is where it matters most to say why
        project = context[:project] || c&.instance_variable_get(:@project) || (c && SeeAs.place_of(c.request.path)[:project])
        issue = c&.instance_variable_get(:@issue)
        issue = nil unless issue.is_a?(::Issue) && issue.persisted?
        v.render(partial: 'gk_people_see_as/menu', locals: { record: SeeAs.record, notice: SeeAs.place_notice(project), project: project,
                                                          issue: issue, elevation: ::GkPeopleElevation.find_by(id: SeeAs.state[:elevation_id]) })
      rescue StandardError => e
        Rails.logger.error("[gk_people] see_as state not shown: #{e.class}: #{e.message}")
        ''
      end
    end
  end
end
