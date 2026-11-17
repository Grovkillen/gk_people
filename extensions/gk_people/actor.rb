# frozen_string_literal: true

module GkPeople
  # actor_records (plugins/people, step 4): who stood at a shared computer. The reserve for shared computers without
  # the agent (the main track is the operator's identity in the agent, where the person gets her own session).
  # * An account is shared when it is a member of the Redmine group the setting names (actor_group_id). Such an
  #   account gets no person of its own: it is a computer, not a person.
  # * At a shared computer one first says who one is (Vem är du?, searched by name); the choice holds until one
  #   changes it, is done, or has been idle longer than the setting, and the top of every page says who it is.
  #   Only the persons on the account's matrix can be chosen (gk_people_shared_account_roles: rows are people groups
  #   and single persons, with Redmine roles per project), and what one may do follows from it: the sum of the roles
  #   on one's rows (one's own and every active group one is in), with the account's own roles as the ceiling (a
  #   permission must be allowed by both). Without a person, nothing. Statuses and how much of the issues one sees
  #   follow the matrix roles, inside the projects where the account is a member.
  # * The person is kept beside the issue or the journal (gk_people_actor_records) with the account that was signed in,
  #   and shown as "Registrerad av <person> via <konto>". Redmine's author is not touched. Not tamper-proof and not
  #   presented as such: it says who the one at the computer said she was.
  # * The same holds for logging time (and changing or deleting a time entry), for editing or emptying one's own note,
  #   and for deleting an issue: a delete first asks who (a page of its own), and the issue's subject is kept with the
  #   record when the issue is gone. As a rule nothing is deleted, but the general solution covers it.
  # * Ways without a form (bulk edit, the context menu's bulk changes, REST, mail in) are refused for a shared account
  #   with a reason. One check (a validation on Issue and TimeEntry) holds for the saves; bulk edit is refused before
  #   it starts.
  module Actor
    THREAD_KEY = :gk_people_actor
    CREATING_KEY = :gk_people_creating_shared
    PARAM = 'gk_people_actor_person_id'
    CAPTURED = %w[manual search token search_pin token_pin].freeze
    KINDS = %w[shared_groups_changed shared_roles_changed shared_pin_changed].freeze

    module_function

    def settings = (::Setting.plugin_gk_people || {})
    def group_id = settings['actor_group_id'].to_i

    def group
      gid = group_id
      gid.positive? ? ::Group.givable.find_by(id: gid) : nil
    end

    def ready?
      ::GkPeopleActorRecord.table_exists?
    rescue StandardError
      false
    end

    # Is the account shared (a member of the group in the setting)
    def shared?(user = ::User.current)
      return false unless user.is_a?(::User) && user.type == 'User' && user.id
      return false unless (gid = group_id).positive?

      ::User.connection.select_value("SELECT 1 FROM groups_users WHERE group_id = #{gid.to_i} AND user_id = #{user.id.to_i} LIMIT 1").present?
    end

    def shared_users
      gid = group_id
      gid.positive? ? ::User.where(type: 'User').where(id: ::User.connection.select_values("SELECT user_id FROM groups_users WHERE group_id = #{gid.to_i}")) : ::User.none
    end

    # Must the issue saved now carry a person: the one signed in is a shared account
    def required?(user = ::User.current) = ready? && shared?(user)

    # The matrix (gk_people_shared_account_roles): on a shared account, rows are people groups and single persons, and
    # per project they get Redmine roles. The one chosen gets the sum of the roles on her rows (her own and those of
    # every active group she is in). The account's own roles are the ceiling: a permission must be allowed by both.
    def matrix_ready?
      ::GkPeopleSharedAccountRole.table_exists?
    rescue StandardError
      false
    end

    def rows(user)
      return ::GkPeopleSharedAccountRole.none unless user&.id && matrix_ready?

      ::GkPeopleSharedAccountRole.where(user_id: user.id)
    end

    def linked?(user) = rows(user).exists?

    # The rows that are the person's: her own, and the active groups she is a member of
    def rows_for(user, person)
      return ::GkPeopleSharedAccountRole.none unless person
      groups = ::GkPeopleGroup.active.where(id: ::GkPeopleGroupMember.where(person_id: person.id).select(:group_id)).select(:id)
      rows(user).where(principal_type: 'person', principal_id: person.id).or(rows(user).where(principal_type: 'group', principal_id: groups))
    end

    def matrix_roles(user, person, project)
      return [] unless project && person

      ::Role.where(id: rows_for(user, person).where(project_id: project.id).select(:role_id)).sorted.to_a
    end

    def matrix_roles_anywhere(user, person) = (person ? ::Role.where(id: rows_for(user, person).select(:role_id)).to_a : [])

    # Who may be chosen at this account: active internal persons on a row (themselves or through an active group);
    # nobody when the account has no rows
    def choosable(user = ::User.current)
      r = rows(user)
      return ::GkPeoplePerson.none unless r.exists?

      via_groups = ::GkPeopleGroupMember.where(group_id: ::GkPeopleGroup.active.where(id: r.where(principal_type: 'group').select(:principal_id)).select(:id)).select(:person_id)
      ::GkPeoplePerson.active.where(kind: 'internal').where(id: r.where(principal_type: 'person').select(:principal_id)).or(
        ::GkPeoplePerson.active.where(kind: 'internal').where(id: via_groups)
      )
    end

    def choosable?(person, user = ::User.current) = person.is_a?(::GkPeoplePerson) && choosable(user).exists?(id: person.id)

    def search(term, user = ::User.current, limit: 10)
      t = term.to_s.strip
      return ::GkPeoplePerson.none if t.length < 2

      choosable(user).search(t).sorted.limit(limit)
    end

    def principal_name(type, id)
      type == 'group' ? ::GkPeopleGroup.find_by(id: id)&.name : ::GkPeoplePerson.find_by(id: id)&.name
    end

    # Sets the whole matrix of a shared account: want is a list of [type, principal_id, project_id, role_id]; an event
    # on the account says what was added and removed
    def set_matrix!(user, want)
      want = want.map { |t, pid, prj, rid| [t.to_s, pid.to_i, prj.to_i, rid.to_i] }.select { |t, *| %w[group person].include?(t) }.uniq
      have = rows(user).pluck(:principal_type, :principal_id, :project_id, :role_id)
      added = want - have
      removed = have - want
      return if added.empty? && removed.empty?

      ::GkPeopleSharedAccountRole.transaction do
        removed.each do |t, pid, prj, rid|
          rows(user).where(principal_type: t, principal_id: pid, project_id: prj, role_id: rid).delete_all
        end
        added.each do |t, pid, prj, rid|
          ::GkPeopleSharedAccountRole.create!(user_id: user.id, principal_type: t, principal_id: pid, project_id: prj, role_id: rid,
                                            created_by_id: (::User.current.logged? ? ::User.current.id : nil))
        end
      end
      # who is a register person or a group of people as records' reference of people's kinds, never a name
      say = lambda do |list|
        list.map do |t, pid, prj, rid|
          who = t == 'group' ? GkPeople::Refs.register_group(pid) : GkPeople::Refs.register_person(pid)
          { 'who' => who, 'project' => ::Project.find_by(id: prj)&.name, 'role' => ::Role.find_by(id: rid)&.name }
        end
      end
      GkPeople.write(user, 'shared_roles_changed', { added: say.call(added), removed: say.call(removed) })
    end

    # The person chosen at the computer (the session): set when the request starts, for this account, until one
    # changes it, is done, or has been idle longer than the setting (minutes)
    SESSION_KEY = :gk_people_actor_session

    def minutes = (settings['actor_minutes'].to_i.positive? ? settings['actor_minutes'].to_i : 10)

    # May Förläng hold the choice longer without saying who one is again (setting actor_prolong, on by default);
    # off, Förläng opens Vem är du?
    def prolong? = settings['actor_prolong'].to_s != '0'

    # Whole seconds before the choice in the session runs out (0 when there is none)
    def seconds_left(session, user)
      s = session[SESSION_KEY]
      return 0 unless s.is_a?(Hash) && s['user_id'].to_i == user.id

      [(minutes * 60) - (Time.current.to_i - s['at'].to_i), 0].max
    end

    # { person:, captured_by:, scheme_id: } from the session, or nil
    def session_given(session, user)
      s = session[SESSION_KEY]
      return nil unless s.is_a?(Hash) && s['user_id'].to_i == user.id
      return nil if Time.now.to_i - s['at'].to_i > minutes * 60

      p = ::GkPeoplePerson.find_by(id: s['person_id'].to_i)
      return nil unless choosable?(p, user)

      { person: p, captured_by: CAPTURED.include?(s['by'].to_s) ? s['by'].to_s : 'search', scheme_id: s['scheme_id'] }
    end

    def session_person(session, user) = session_given(session, user)&.dig(:person)

    # by: how she said who she is (search, token, search_pin, token_pin); scheme_id: the badge's scheme
    def choose!(session, user, person, by: 'search', scheme_id: nil)
      session[SESSION_KEY] = { 'user_id' => user.id, 'person_id' => person.id, 'at' => Time.now.to_i, 'by' => by, 'scheme_id' => scheme_id }
    end

    def done!(session) = session.delete(SESSION_KEY)

    def touch!(session)
      session[SESSION_KEY]['at'] = Time.now.to_i if session[SESSION_KEY].is_a?(Hash)
    end

    # Account roles, not the matrix (the ceiling check inside User#allowed_to?)
    def raw
      before = Thread.current[:gk_people_actor_raw]
      Thread.current[:gk_people_actor_raw] = true
      yield
    ensure
      Thread.current[:gk_people_actor_raw] = before
    end

    def raw? = Thread.current[:gk_people_actor_raw] == true

    # Does the matrix decide for this account now (a shared account, the actor records ready, not inside the ceiling
    # check)
    def matrix_for?(user) = !raw? && matrix_ready? && shared?(user)

    # User: in a project where the account is a member, its roles are the matrix roles of the person chosen (none
    # without a person); a permission must also be allowed by the account's own roles (the ceiling)
    module UserPatch
      def roles_for_project(project)
        roles = super
        return roles unless GkPeople::Actor.matrix_for?(self) && membership(project)

        GkPeople::Actor.matrix_roles(self, GkPeople::Actor.current&.dig(:person), project)
      end

      def projects_by_role
        return super unless GkPeople::Actor.matrix_for?(self)

        person = GkPeople::Actor.current&.dig(:person)
        @gk_people_pbr ||= {}
        @gk_people_pbr[person&.id] ||= begin
          projects = super.values.flatten.uniq
          h = Hash.new([])
          projects.each do |project|
            GkPeople::Actor.matrix_roles(self, person, project).each { |r| h[r] = (h[r] + [project]).uniq }
          end
          h
        end
      end

      def allowed_to?(action, context, options = {}, &block)
        ok = super
        return ok unless ok && GkPeople::Actor.matrix_for?(self)

        if context.nil? && options[:global]
          person = GkPeople::Actor.current&.dig(:person)
          return GkPeople::Actor.matrix_roles_anywhere(self, person).any? { |r| r.allowed_to?(action) }
        end
        GkPeople::Actor.raw { super }
      end
    end

    # The person chosen is picked up when the request starts (after core has found the account). Without one, a page
    # opened on a shared account goes to Vem är du? first; the rest (script, REST, the choice itself) goes on, and
    # what it may do follows from the matrix (nothing without a person).
    module SessionPatch
      FREE = %w[gk_people_actor account].freeze
      # Förläng decides itself whether the choice is held longer (the setting), so its own request does not touch it
      UNTOUCHED = [%w[gk_people_actor prolong]].freeze

      private

      def process_action(*args)
        super
      ensure
        Thread.current[GkPeople::Actor::THREAD_KEY] = nil
      end

      def user_setup
        r = super
        user = ::User.current
        return r unless GkPeople::Actor.required?(user)
        return r if defined?(GkPeople::SeeAs) && GkPeople::SeeAs.state # Se som: only looking
        # The gate to GK GUI Stuff is closed (gate.rb): nobody can say who she is (the page, the band and the form's
        # field are interface), so no person is picked up, not one chosen before the gate closed either, and nobody is
        # sent to the page that is closed. Without a person the matrix gives no roles: core's own refusal.
        return r unless GkPeople.gui?

        given = GkPeople::Actor.session_given(session, user)
        if given
          GkPeople::Actor.touch!(session) unless UNTOUCHED.include?([controller_name, action_name])
          Thread.current[GkPeople::Actor::THREAD_KEY] = given
        elsif request.get? && !request.xhr? && !api_request? && !FREE.include?(controller_name) && request.format.html?
          redirect_to gk_people_actor_who_path(back_url: request.fullpath)
        end
        r
      end
    end

    # Rights for a person at the computer, for the scenario and the pages
    def may?(user, person, permission, project, issue: nil)
      before = ::User.current
      ::User.current = user
      as_person(person) do
        u = ::User.find(user.id)
        issue ? ::Issue.find(issue.id).send(:user_tracker_permission?, u, permission.to_sym) : u.allowed_to?(permission.to_sym, project)
      end
    ensure
      ::User.current = before
    end

    # The person given for this request: { person:, captured_by:, scheme_id: } or nil
    def current = Thread.current[THREAD_KEY]

    # Every page on a shared account says who is chosen at the computer, in the top band: gui_stuff's band, after the
    # instance's role, also in production and when the instance band is off; nothing in the corner band or the menu.
    # Not while Se som only looks.
    def band?(user = ::User.current) = required?(user) && !(defined?(GkPeople::SeeAs) && GkPeople::SeeAs.state)

    # The session's choice for the page being drawn, read once per page (the part's words, role and panel all ask)
    def band_given(view)
      return view.instance_variable_get(:@gk_people_band_given) if view.instance_variable_defined?(:@gk_people_band_given)

      view.instance_variable_set(:@gk_people_band_given, session_given(view.session, ::User.current))
    end

    # The shared computer as a part of the top band: the person's name at the computer in the role info (the first
    # name when the band is short, the icon alone on a phone), or Ingen vald vid datorn in the quiet role. Its panel
    # has the account and the minutes left, Byt person… and Klar, or Vem är du? when nobody is chosen. The band says the
    # session's choice, never the person a form gave for one save (a form re-drawn after a refused save runs inside
    # as_person with the form's person). The warning a minute before the choice runs out (gk_people_actor.js) reads
    # the part's data.
    def register_band!
      ::GkGuiStuff::TopBand.register(
        'people.actor', plugin: :gk_people, weight: :shared_computer, icon: 'user', condition: ->(_view) { band? },
                        role: ->(view) { band_given(view) ? :info : :quiet },
                        full: lambda { |view|
                          g = band_given(view)
                          g ? ::I18n.t(:text_gk_people_actor_band, person: g[:person].name) : ::I18n.t(:text_gk_people_actor_band_none)
                        },
                        short: lambda { |view|
                          g = band_given(view)
                          if g
                            ::I18n.t(:text_gk_people_actor_band, person: g[:person].first_name.presence || g[:person].name)
                          else
                            ::I18n.t(:text_gk_people_actor_band_none_short)
                          end
                        },
                        title: lambda { |view|
                          g = band_given(view)
                          g ? ::I18n.t(:text_gk_people_actor_band_title, person: g[:person].name) : ::I18n.t(:text_gk_people_actor_band_none)
                        },
                        html: ->(view) { band_data(view) },
                        panel: ->(view) { view.render(partial: 'gk_people_actor/band_panel', locals: { given: band_given(view) }) }
      )
    end

    # The part's class and, when someone is chosen, what the warning before the end needs
    def band_data(view)
      g = band_given(view)
      return { class: 'gk-people-actor-bar' } unless g

      back = band_back(view)
      { class: 'gk-people-actor-bar',
        data: { seconds_left: seconds_left(view.session, ::User.current), prolong_url: (view.gk_people_actor_prolong_path if prolong?),
                who_url: view.gk_people_actor_who_path(back_url: back), warn: ::I18n.t(:text_gk_people_actor_minute_left, person: g[:person].name),
                prolong: ::I18n.t(:button_gk_people_actor_prolong) } }
    end

    # Where Vem är du? and Byt person… lead back to: the page itself, when it is a page to come back to
    def band_back(view)
      r = view.request
      r.get? && view.controller_name != 'gk_people_actor' ? r.fullpath : nil
    end

    def as_person(person, captured_by: 'search', scheme_id: nil)
      before = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = person ? { person: person, captured_by: CAPTURED.include?(captured_by.to_s) ? captured_by.to_s : 'search', scheme_id: scheme_id } : nil
      yield
    ensure
      Thread.current[THREAD_KEY] = before
    end

    # A shared account being made (by the scenario, or an admin tool): it gets no person
    def creating_shared
      before = Thread.current[CREATING_KEY]
      Thread.current[CREATING_KEY] = true
      yield
    ensure
      Thread.current[CREATING_KEY] = before
    end

    def creating_shared? = Thread.current[CREATING_KEY] == true

    ACTIONS = %w[created updated note_edited deleted time_logged time_updated time_deleted].freeze
    # Shown under the issue's details (the creation) and under a journal
    ISSUE_LINES = %w[created updated note_edited].freeze
    PENDING_KEY = :gk_people_actor_pending
    PENDING_SECONDS = 300

    # What is wrong with the person given now, as a locale key, or nil (for a shared account signed in)
    def problem(user = ::User.current)
      return :error_gk_people_actor_no_groups unless linked?(user)

      given = current
      return :error_gk_people_actor_missing if given.nil?
      return :error_gk_people_actor_not_choosable unless choosable?(given[:person], user)

      nil
    end

    # One thing done on a shared account: what (ACTIONS), on what, by which person, through which account. details
    # keeps what is needed when the thing is gone (a deleted issue's subject, the hours of a time entry).
    def record!(action, issue: nil, journal: nil, time_entry: nil, project: nil, details: nil, user: ::User.current, given: current)
      return unless given && user&.id

      ::GkPeopleActorRecord.create!(action: action, issue_id: issue&.id, journal_id: journal&.id, time_entry_id: time_entry&.id,
                                  project_id: (project || issue&.project || time_entry&.project)&.id, person_id: given[:person].id,
                                  user_id: user.id, captured_by: given[:captured_by], scheme_id: given[:scheme_id],
                                  details: details&.to_json, captured_at: Time.current)
    end

    # The lines on an issue: { journal_id (nil for the creation) => [records] }
    def for_issue(issue)
      return {} unless issue&.id && ready?

      ::GkPeopleActorRecord.where(issue_id: issue.id, action: ISSUE_LINES).includes(:person, :user).order(:id).to_a.group_by(&:journal_id)
    end

    def may_view_records?(user = ::User.current) = user.admin? || user.allowed_to?(:gk_people_view_actor_records, nil, global: true)

    # A journal being edited by its own author (JournalsController#update): its saves and its removal are recorded
    def editing_journal(journal)
      before = Thread.current[:gk_people_editing_journal]
      Thread.current[:gk_people_editing_journal] = journal.id
      yield
    ensure
      Thread.current[:gk_people_editing_journal] = before
    end

    def editing_journal?(journal) = Thread.current[:gk_people_editing_journal] == journal.id

    # The person from a form: the field, the list without script, or (for a delete that core answers with a page of
    # its own, the hours of a deleted issue) the person chosen for the same address a moment ago
    def person_from(controller, pending: false)
      params = controller.params
      id = (params[PARAM].presence || params["#{PARAM}_noscript"]).to_s
      session = controller.session
      if id.match?(/\A\d+\z/)
        session[PENDING_KEY] = { 'person_id' => id.to_i, 'path' => controller.request.path, 'at' => Time.now.to_i } if pending
      elsif pending && (p = session[PENDING_KEY]).is_a?(Hash) && p['path'] == controller.request.path && Time.now.to_i - p['at'].to_i < PENDING_SECONDS
        id = p['person_id'].to_s
      end
      id.match?(/\A\d+\z/) ? ::GkPeoplePerson.find_by(id: id.to_i) : nil
    end

    # Validation and the records. Issue and TimeEntry: a validation and the records after save and after destroy;
    # Journal: the records when its author edits or empties it. All of it does nothing unless a shared account is
    # signed in.
    module Checked
      private

      def gk_people_actor_given
        return unless GkPeople::Actor.required?

        key = GkPeople::Actor.problem
        errors.add(:base, ::I18n.t(key)) if key
      end
    end

    module IssuePatch
      include Checked

      def self.prepended(base)
        base.validate :gk_people_actor_given
        base.after_save :gk_people_actor_record
        base.after_destroy :gk_people_actor_deleted
      end

      private

      # After create_journal (core's after_save comes first), so the journal of this save has its id
      def gk_people_actor_record
        return unless GkPeople::Actor.required? && GkPeople::Actor.current

        if saved_change_to_id?
          GkPeople::Actor.record!('created', issue: self)
        elsif current_journal&.persisted?
          GkPeople::Actor.record!('updated', issue: self, journal: current_journal)
        end
      end

      # Core checks the permissions per tracker (add, edit, delete, notes) on the roles directly, past allowed_to?:
      # the ceiling holds there too
      def user_tracker_permission?(user, permission)
        ok = super
        return ok unless ok && GkPeople::Actor.matrix_for?(user)

        GkPeople::Actor.raw { super }
      end

      # Kept when the issue is gone: who removed it, and what it was
      def gk_people_actor_deleted
        return unless GkPeople::Actor.required? && GkPeople::Actor.current

        GkPeople::Actor.record!('deleted', issue: self, project: project,
                                            details: { id: id, subject: subject, tracker: tracker&.name, project: project&.name })
      end
    end

    # The trackers one may create issues in: those the matrix gives, inside those the account itself may use
    module IssueClassPatch
      def allowed_target_trackers(project, user = ::User.current, current_tracker = nil)
        scope = super
        return scope unless project && GkPeople::Actor.matrix_for?(user)

        scope.where(id: GkPeople::Actor.raw { super }.select(:id))
      end
    end

    module TimeEntryPatch
      include Checked

      def self.prepended(base)
        base.validate :gk_people_actor_given
        base.after_create :gk_people_actor_logged
        base.after_update :gk_people_actor_changed
        base.after_destroy :gk_people_actor_removed
      end

      private

      def gk_people_actor_details = { hours: hours.to_f, spent_on: spent_on&.to_s, activity: activity&.name, issue_id: issue_id }

      def gk_people_actor_logged
        return unless GkPeople::Actor.required? && GkPeople::Actor.current

        GkPeople::Actor.record!('time_logged', issue: issue, time_entry: self, project: project, details: gk_people_actor_details)
      end

      def gk_people_actor_changed
        return unless GkPeople::Actor.required? && GkPeople::Actor.current && saved_changes.except('updated_on').any?

        GkPeople::Actor.record!('time_updated', issue: issue, time_entry: self, project: project, details: gk_people_actor_details)
      end

      def gk_people_actor_removed
        return unless GkPeople::Actor.required? && GkPeople::Actor.current

        GkPeople::Actor.record!('time_deleted', issue: issue, time_entry: self, project: project, details: gk_people_actor_details)
      end
    end

    module JournalPatch
      def self.prepended(base)
        base.after_update :gk_people_actor_edited
        base.after_destroy :gk_people_actor_emptied
      end

      private

      def gk_people_actor_edited
        return unless GkPeople::Actor.editing_journal?(self) && GkPeople::Actor.required? && GkPeople::Actor.current

        GkPeople::Actor.record!('note_edited', issue: (journalized if journalized_type == 'Issue'), journal: self)
      end

      def gk_people_actor_emptied
        return unless GkPeople::Actor.editing_journal?(self) && GkPeople::Actor.required? && GkPeople::Actor.current

        GkPeople::Actor.record!('note_edited', issue: (journalized if journalized_type == 'Issue'), journal: self, details: { removed: true })
      end
    end

    # Shared by the controllers: the person from the form around a save; a delete asks who first (a page of its own,
    # since core deletes from a link); bulk edit refused; REST never carries a person, so the validation refuses it
    module ControllerSupport
      private

      def gk_people_with_actor(&block)
        return yield unless GkPeople::Actor.required?
        return deny_access unless GkPeople.gui? # nobody can say who she is (gate.rb): core's own refusal
        return yield if api_request? || GkPeople::Actor.current # REST: refused by the validation; the session: its person
        return gk_people_refuse_for_pin if GkPeople::SharedAccounts.require_pin?(::User.current)

        # the form only searches by name: how she was captured is not taken from the client (a badge and a PIN are
        # checked at Vem är du? and come with the session)
        GkPeople::Actor.as_person(GkPeople::Actor.person_from(self), captured_by: 'search', &block)
      end

      def gk_people_destroy_with_actor(&block)
        return yield unless GkPeople::Actor.required?
        return deny_access unless GkPeople.gui? # the question who is a page of people's (gate.rb): core's own refusal
        return render_error(message: l(:error_gk_people_actor_rest), status: 403) if api_request?
        return yield if GkPeople::Actor.current # the person chosen at the computer
        return gk_people_refuse_for_pin if GkPeople::SharedAccounts.require_pin?(::User.current)

        person = GkPeople::Actor.person_from(self, pending: true)
        key = GkPeople::Actor.as_person(person) { GkPeople::Actor.problem }
        if key
          @gk_people_error = (l(key) if params[GkPeople::Actor::PARAM].present? || params.key?(:gk_people_actor_by))
          @gk_people_passthrough = params.permit(:todo, :reassign_to_id, :back_url, ids: []).to_h
          @gk_people_passthrough['ids'] ||= [params[:id]].compact
          # core goes back to the page before (the referer) after a delete; that would be this question, so the page
          # the delete came from goes along. Both a back_url sent along and the referer go through core's
          # validate_back_url; one that fails is dropped, so the page never carries it on
          back = GkPeople::BackUrl.pick(validate_back_url(@gk_people_passthrough['back_url'].to_s)) ||
                 GkPeople::BackUrl.pick(validate_back_url(request.referer.to_s), not_path: request.path)
          @gk_people_passthrough.delete('back_url')
          @gk_people_passthrough['back_url'] = back if back
          @gk_people_cancel_path = gk_people_destroy_fallback_path
          return render(template: 'gk_people_actor/confirm_destroy', layout: 'base')
        end
        GkPeople::Actor.as_person(person, &block)
      end

      # Where Cancel on the delete question goes when no checked page came along (no referer, or one that
      # validate_back_url refused): a fixed page made with core's route helpers, never the raw referer. One issue: the
      # issue; several: the project's (or all) issues; time entries: the project's (or all) time entries. core's
      # find_issues and find_time_entries have set @issues, @time_entries and @project (nil across projects) by now.
      def gk_people_destroy_fallback_path
        if controller_name == 'timelog'
          _time_entries_path(@project, nil)
        elsif @issues.is_a?(Array) && @issues.size == 1
          issue_path(@issues.first)
        else
          _project_issues_path(@project)
        end
      end

      def gk_people_refuse_bulk
        return unless GkPeople::Actor.required?
        return deny_access unless GkPeople.gui? # no words of people's own while the gate is closed (gate.rb): core's refusal

        render_error(message: l(:error_gk_people_actor_bulk), status: 403)
      end

      # An account that requires a PIN takes the person only from Vem är du? (badge or name, then the PIN): the form's
      # field (where the account is no member of the project) would pass the PIN by, so it is refused with the way
      # there, back to the page the form was on
      def gk_people_refuse_for_pin
        from = GkPeople::BackUrl.pick(validate_back_url(request.referer.to_s), not_under: File.dirname(gk_people_actor_who_path))
        flash[:error] = l(:error_gk_people_actor_pin_use_who)
        redirect_to gk_people_actor_who_path(back_url: from)
      end
    end

    module IssuesControllerPatch
      include ControllerSupport

      def self.prepended(base)
        base.around_action :gk_people_with_actor, only: %i[create update]
        base.around_action :gk_people_destroy_with_actor, only: %i[destroy]
        base.before_action :gk_people_refuse_bulk, only: %i[bulk_edit bulk_update]
      end
    end

    module TimelogControllerPatch
      include ControllerSupport

      def self.prepended(base)
        base.around_action :gk_people_with_actor, only: %i[create update]
        base.around_action :gk_people_destroy_with_actor, only: %i[destroy]
        base.before_action :gk_people_refuse_bulk, only: %i[bulk_edit bulk_update]
      end
    end

    # Editing one's own note: the person comes with the note's own small form (it is sent with script)
    module JournalsControllerPatch
      def self.prepended(base)
        base.around_action :gk_people_journal_with_actor, only: %i[update]
      end

      private

      def gk_people_journal_with_actor(&block)
        return yield unless GkPeople::Actor.required?
        return deny_access unless GkPeople.gui? # nobody can say who she is (gate.rb): core's own refusal
        return render_error(message: l(:error_gk_people_actor_rest), status: 403) if api_request?
        return GkPeople::Actor.editing_journal(@journal, &block) if GkPeople::Actor.current

        person = GkPeople::Actor.person_from(self)
        # an account that requires a PIN: only Vem är du? gives the person (as for issues and time)
        key = if GkPeople::SharedAccounts.require_pin?(::User.current)
                :error_gk_people_actor_pin_use_who
              else
                GkPeople::Actor.as_person(person) { GkPeople::Actor.problem }
              end
        if key && !request.xhr?
          flash[:error] = l(key)
          return redirect_to(@journal.journalized.is_a?(::Issue) ? issue_path(@journal.journalized) : home_path)
        end
        if key
          # core's remote edit asks for a script; the reply is the plugin's own template, not code built here
          return render(template: 'gk_people_actor/journal_error', formats: [:js], layout: false,
                        locals: { form: "journal-#{@journal.id.to_i}-form", text: l(key) })
        end
        GkPeople::Actor.as_person(person) { GkPeople::Actor.editing_journal(@journal, &block) }
      end
    end

    # The field in the forms, and the lines under a journal and under the issue's details
    class Hooks < Redmine::Hook::ViewListener
      include GkPeople::Gate::Listener # silent without GK GUI Stuff (gate.rb)
      # The new issue's form (re-rendered when the tracker or status changes, so the choice is read back from params)
      def view_issues_form_details_bottom(context = {})
        issue = context[:issue]
        return '' unless issue&.new_record? && GkPeople::Actor.required?

        field(context, 'issue')
      end

      # The edit form: under the notes, which every one who may edit or add a note sees
      def view_issues_edit_notes_bottom(context = {})
        return '' unless GkPeople::Actor.required?

        field(context, 'edit')
      end

      # Logging time, and changing a time entry
      def view_timelog_edit_form_bottom(context = {})
        return '' unless GkPeople::Actor.required?

        field(context, 'time')
      end

      # Editing one's own note
      def view_journals_notes_form_after_notes(context = {})
        j = context[:journal]
        return '' unless j && GkPeople::Actor.required?

        field(context, "journal_#{j.id}")
      end

      # Mitt konto: one's own PIN for shared computers (only for an account with a person)
      def view_my_account_contextual(context = {})
        v = context[:hook_caller]
        return '' unless v && GkPeople.feature?('people.pin') && GkPeople::Pin.ready? && GkPeople.person_for(::User.current)

        v.link_to(v.sprite_icon('key', ::I18n.t(:label_gk_people_my_pin)), v.gk_people_my_pin_path, class: 'icon icon-key', id: 'gk-people-my-pin')
      rescue StandardError => e
        Rails.logger.error("[gk_people] my PIN link not shown: #{e.class}: #{e.message}")
        ''
      end

      # Administration, the shared account: who stands at this computer (its people groups), as a link (the hook is
      # inside core's form, so no form of its own here)
      def view_users_form(context = {})
        user = context[:user]
        v = context[:hook_caller]
        return '' unless v && user&.persisted? && GkPeople::Actor.shared?(user)

        v.render(partial: 'gk_people_actor/admin_user', locals: { user: user })
      end

      def view_issues_history_journal_bottom(context = {})
        j = context[:journal]
        v = context[:hook_caller]
        return '' unless j && v && j.journalized_type == 'Issue'

        lines(v, records(v, j.journalized)[j.id])
      rescue StandardError => e
        Rails.logger.error("[gk_people] actor line not shown: #{e.class}: #{e.message}")
        ''
      end

      def view_issues_show_details_bottom(context = {})
        issue = context[:issue]
        v = context[:hook_caller]
        return '' unless issue && v

        lines(v, records(v, issue)[nil])
      rescue StandardError => e
        Rails.logger.error("[gk_people] actor line not shown: #{e.class}: #{e.message}")
        ''
      end

      private

      def field(context, uid)
        v = context[:hook_caller]
        return '' unless v

        id = v.params[GkPeople::Actor::PARAM].to_s
        chosen = id.match?(/\A\d+\z/) ? ::GkPeoplePerson.find_by(id: id.to_i) : nil
        chosen = nil unless GkPeople::Actor.choosable?(chosen)
        v.render(partial: 'gk_people_actor/field', locals: { chosen: chosen, account: ::User.current, uid: uid })
      end

      def lines(view, recs)
        return '' if recs.blank?

        view.safe_join(recs.map { |r| view.render(partial: 'gk_people_actor/line', locals: { record: r }) })
      end

      # Once per issue and page
      def records(view, issue)
        cache = view.instance_variable_get(:@gk_people_actor_records) || {}
        view.instance_variable_set(:@gk_people_actor_records, cache)
        cache[issue.id] ||= GkPeople::Actor.for_issue(issue)
      end
    end
  end
end
