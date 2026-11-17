# frozen_string_literal: true

module GkPeople
  # The gate to GK GUI Stuff, which people requires. It is open when GK GUI Stuff answers the gate's questions, its
  # base version (the version without a candidate's suffix) is the lowest one people needs or later, and its own gate
  # is open; candidates of one base version are not told apart.
  #
  # A gate closes only the interface, never a protection or a trace. Closed, the gate closes what a person works with:
  # the pages, the menu rows, the REST API, what people draws on other pages (the view listeners, the helper in every
  # view, the group's own page), Se som, the chat program's choice and what people registers for a page in other
  # plugins (GK GUI Stuff's registers, the reason places, the translations, the picture sources, the review content,
  # the taggables, the record of processing). The questions that only open a page answer no (Access.view?, manage?,
  # identifiers?, Responsibilities.manage?), SeeAs.active? is false, and Processing and Owner answer nothing. It never
  # closes:
  # * the core patches that refuse, lock, hide or write traces (the :protect rows of Patches::ORDER in patches.rb): the account and
  #   membership events and the person of a new account, elevation, the reserve accounts, what those outside see of a
  #   name, the shared account's matrix and its records, and the role sync;
  # * the targets and the event kinds in GK Records' register (register_records!), so the events are written; GK
  #   Records marks an event written while the gate is closed in its details;
  # * people's functions in GK Records' register and the role sync's job in GK Ops (RoleSync.ops_registrations!);
  # * the questions protection asks: GkPeople.person_for, GkPeople.feature?, Refs.thing and Responsibilities (ready?,
  #   find, in_force, holders, unavailable?, for_person, vacancies) answer as with an open gate. What draws for a
  #   function asks the gate itself;
  # * the permissions: init.rb registers them whatever the gate says. Core's role form lists only the permissions that
  #   are registered and Role#permissions= writes the whole list, so a role saved while they were away would lose
  #   them. With the gate closed they open nothing: the controllers answer 404 and the menu rows are gone.
  # Two things follow from the interface being closed:
  # * elevation cannot ask for the step up, so it still opens: every admin flag is full admin, as when the layer is
  #   off. Where the layer would have held, the opening is kept as an elevation of its own (method gate) with what is
  #   changed under it, and as an event on the account (Elevation.setup_gate!): one for each session, and one at a
  #   time for the account's requests that carry no session;
  # * nobody can say who she is at a shared computer (Vem är du?, the band and the form's field are interface), so a
  #   shared account can do nothing while the gate is closed and gets core's own refusal.
  # The settings page says the first thing that is not met in one line of core's own form (<p class="warning">)
  # beside the About box, and that protection and traces hold all the same; the migrations run all the same, so
  # nothing is lost when GK GUI Stuff comes in.

  # The lowest base version the gate opens for; IDENTITY.yml requires the same base and a test holds the two together
  GUI_STUFF_MIN = '1.05.000'

  #   GkPeople.gui_closed -> nil when the gate is open; otherwise the first thing that is not met: :missing (no GK GUI
  #   Stuff), :old (it does not answer open?, or its base version is older than GUI_STUFF_MIN) or :inactive (its own
  #   gate is closed)
  def self.gui_closed
    return :missing unless defined?(::GkGuiStuff)
    return :old unless ::GkGuiStuff.respond_to?(:open?) && ::GkGuiStuff.respond_to?(:version_at_least?) &&
                       ::GkGuiStuff.version_at_least?(GUI_STUFF_MIN)
    return :inactive unless ::GkGuiStuff.open?

    nil
  rescue StandardError
    :missing
  end

  #   GkPeople.gui? -> true when gui_closed has nothing to say
  def self.gui? = gui_closed.nil?

  module Gate
    #   Gate.line -> nil when the gate is open; otherwise the settings page's line for the first thing that is not
    #   met, as text without the link, in I18n's current language. For the rake tasks: there that is Redmine's fixed
    #   default, en (config.i18n.default_locale), not the instance's default language
    def self.line
      case GkPeople.gui_closed
      when :missing then ::I18n.t(:text_gk_people_gui_stuff_missing)
      when :old then ::I18n.t(:text_gk_people_gui_stuff_required, version: GUI_STUFF_MIN)
      when :inactive then ::I18n.t(:text_gk_people_gui_stuff_inactive)
      end
    end

    #   Gate.rows(records) { |record| address } -> [[name, address], ...] for what people reports in GK Ops (an
    #   invariant's rows). The report is a trace and is made whatever the gate says, but the address leads to one of
    #   people's pages, and they are closed with the gate: closed, a row is given without an address (nil) and GK Ops
    #   draws the name alone. The gate is asked when the rows are asked for, not when the invariant is registered
    def self.rows(records)
      open = GkPeople.gui?
      records.map { |r| [r.name, open ? yield(r) : nil] }
    end

    # The hook methods a view or controller listener answers (view_*, controller_*, model_*). Redmine asks a listener
    # respond_to?(hook) once and keeps the answer (Redmine::Hook.hook_listeners), so a closed gate keeps every hook of
    # people's listeners silent. A listener is registered as soon as its class is defined (Listener.inherited), so the
    # gate is in the listener and not in init.rb.
    HOOK = /\A(view|controller|model)_/

    module Listener
      def respond_to?(name, include_all = false)
        return false if HOOK.match?(name.to_s) && !GkPeople.gui?

        super
      end
    end

    # Every people controller (the pages and the REST API) is closed without GK GUI Stuff: core's 404. A plain
    # before_action, after the ones ApplicationController has (the session, the user, the language), so that the 404 is
    # drawn for the person and in the language of the request; before the controller's own (require_login and the like)
    module Controller
      def self.included(base)
        base.before_action :gk_people_gate
      end

      private

      def gk_people_gate
        render_404 unless GkPeople.gui?
      end
    end
  end
end
