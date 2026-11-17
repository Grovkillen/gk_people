# frozen_string_literal: true

module GkPeople
  # Core patches, all applied from here, in this order; the modules stay beside the code they serve, and what each
  # assumes of core is listed in plugins/people, Core-patchar. Two layers (gate.rb): what refuses, locks, hides or
  # writes traces is applied whatever the gate to GK GUI Stuff says (:protect); what draws or is a way of working is
  # applied only with the gate open (:interface: Se som, the helper in every view and the chat program's choice).
  # * Account and membership events from the models, and the group's own (UserPatch, MemberPatch, MemberRolePatch,
  #   GroupPatch: account_events.rb, groups.rb).
  # * elevation: User#admin? and ApplicationController (user_setup, process_action, require_admin, deny_access,
  #   logout_user). Off unless the setting is on and an admin has a person.
  # * Reserve accounts: User (the owner's password and lock follow), Setting (saving the settings makes, renames and
  #   retires them) and Principal's scopes.
  # * Se som: ApplicationController (the request as the one looked as, read only, rolled back) and
  #   ActionMailer::MessageDelivery (no mail delivered under it).
  # * What those outside see (outward.rb): User#name for one not signed in while a page is drawn (never in a mail),
  #   ApplicationController (an around_action), Mailer#mail and two choices in UserPreference.
  # * actor_records: User (roles_for_project, projects_by_role, allowed_to?), ApplicationController (user_setup,
  #   process_action), Issue and its class, IssuesController, TimeEntry, Journal, TimelogController and
  #   JournalsController. All idle unless a shared account is signed in.
  # * role_sync: MemberRole (a role people gave, removed by hand, is noted as a deviation) and ApplicationController
  #   (user_setup: the daily run at the first request after midnight).
  # * GkPeopleHelper in ActionView::Base: every view class inherits from it, so the helpers answer in every view;
  #   every name in the module carries the gk_people_ prefix.
  # * The chat program's choice in UserPreference (name_links.rb).
  #
  # The same method prepended more than once on ApplicationController. The module prepended last runs first, so the
  # order below decides:
  # * user_setup, prepended Elevation, SeeAs, Actor, RoleSync: Elevation's Reserve.tick! runs before core, then after
  #   core's user_setup Elevation.setup!, then Se som (refused or read only), then actor_records (the person at the
  #   computer, nothing while looking as someone), last role_sync's daily run (not while looking as someone).
  # * process_action, prepended Elevation, SeeAs, Actor: actor_records outermost (its ensure clears the person last),
  #   then Se som's transaction, then elevation's ensure (after_request!, clear!), inside that transaction.
  # * logout_user, prepended Elevation, SeeAs: Se som is stopped first, then elevation steps down, then core.
  # Because the order decides, the two layers are one list (ORDER) and init.rb applies it in one pass (install!),
  # passing over the interface rows while the gate is closed: with the gate open the order is the list's, whole. The
  # gate's answer does not change while the process runs; a module once prepended stays, and one prepended later than
  # its row would stand outermost.
  # Applied directly from init.rb, which Redmine runs inside to_prepare at start and again after every reload in
  # development mode; every prepend is guarded, so a reload never adds a module twice.
  module Patches
    # [layer, the core class, people's module, how]: :prepend on the class, :singleton on its singleton class,
    # :include into it. Names, so that the list can be read before core's classes are loaded.
    ORDER = [
      [:protect, 'User', 'GkPeople::UserPatch', :prepend],
      # elevation
      [:protect, 'User', 'GkPeople::Elevation::UserPatch', :prepend],
      [:protect, 'ApplicationController', 'GkPeople::Elevation::ControllerPatch', :prepend],
      # Reserve accounts
      [:protect, 'User', 'GkPeople::Reserve::UserPatch', :prepend],
      [:protect, 'Setting', 'GkPeople::Reserve::SettingPatch', :prepend],
      [:protect, 'Principal', 'GkPeople::Reserve::PrincipalScopes', :singleton],
      # Se som
      [:interface, 'ApplicationController', 'GkPeople::SeeAs::ControllerPatch', :prepend],
      [:interface, 'ActionMailer::MessageDelivery', 'GkPeople::SeeAs::DeliveryGuard', :prepend],
      [:protect, 'Member', 'GkPeople::MemberPatch', :prepend],
      # What those outside see
      [:protect, 'User', 'GkPeople::Outward::UserPatch', :prepend],
      [:protect, 'ApplicationController', 'GkPeople::Outward::ControllerPatch', :prepend],
      [:protect, 'Mailer', 'GkPeople::Outward::MailerPatch', :prepend],
      [:protect, 'UserPreference', 'GkPeople::Outward::PreferencePatch', :prepend],
      [:protect, 'MemberRole', 'GkPeople::MemberRolePatch', :prepend],
      [:protect, 'Group', 'GkPeople::GroupPatch', :prepend],
      # actor_records
      [:protect, 'User', 'GkPeople::Actor::UserPatch', :prepend],
      [:protect, 'ApplicationController', 'GkPeople::Actor::SessionPatch', :prepend],
      [:protect, 'Issue', 'GkPeople::Actor::IssuePatch', :prepend],
      [:protect, 'Issue', 'GkPeople::Actor::IssueClassPatch', :singleton],
      [:protect, 'IssuesController', 'GkPeople::Actor::IssuesControllerPatch', :prepend],
      [:protect, 'TimeEntry', 'GkPeople::Actor::TimeEntryPatch', :prepend],
      [:protect, 'Journal', 'GkPeople::Actor::JournalPatch', :prepend],
      [:protect, 'TimelogController', 'GkPeople::Actor::TimelogControllerPatch', :prepend],
      [:protect, 'JournalsController', 'GkPeople::Actor::JournalsControllerPatch', :prepend],
      # role_sync
      [:protect, 'MemberRole', 'GkPeople::RoleSync::MemberRolePatch', :prepend],
      [:protect, 'ApplicationController', 'GkPeople::RoleSync::DailyPatch', :prepend],
      [:interface, 'ActionView::Base', 'GkPeopleHelper', :include],
      # the chat program's choice
      [:interface, 'UserPreference', 'GkPeople::NameLinks::PreferencePatch', :prepend]
    ].freeze

    module_function

    #   Patches.install! -> what init.rb calls: every row of ORDER in its order, the interface rows only with the gate
    #   to GK GUI Stuff open
    def install!
      open = GkPeople.gui?
      ORDER.each { |row| put(row) if open || row[0] == :protect }
      nil
    end

    def put((_layer, target, patch, how))
      klass = Object.const_get(target)
      mod = Object.const_get(patch)
      case how
      when :include then klass.include(mod) unless klass.include?(mod)
      when :singleton then klass.singleton_class.prepend(mod) unless klass.singleton_class < mod
      else klass.prepend(mod) unless klass < mod
      end
    end
  end
end
