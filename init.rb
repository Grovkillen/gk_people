# frozen_string_literal: true
# Depends on: gk_gui_stuff 1.05.000 or later required; optional gk_records, gk_fields, gk_ops, gk_project_types,
# gk_revisions, gk_tags, gk_icons, gk_compat, gk_core_stuff, gk_scenarios. Without gk_gui_stuff (missing, too old or
# not active: GkPeople.gui?, gate.rb) the pages, the menus, what people draws on other pages and the API are closed,
# and the settings page says so. Protection and traces hold all the same: the core patches that refuse, lock, hide
# or write traces, the events in GK Records, the role sync, and the registered permissions. The migrations run all
# the same.

require_relative 'extensions/gk_people/gate'
require_relative 'extensions/gk_people/core'
require_relative 'extensions/gk_people/registers'
require_relative 'extensions/gk_people/accounts'
require_relative 'extensions/gk_people/groups'
require_relative 'extensions/gk_people/account_events'
require_relative 'extensions/gk_people/hooks'
require_relative 'extensions/gk_people/name_links'
require_relative 'extensions/gk_people/processing'
require_relative 'extensions/gk_people/person_groups'
require_relative 'extensions/gk_people/elevation'
require_relative 'extensions/gk_people/reserve'
require_relative 'extensions/gk_people/see_as'
require_relative 'extensions/gk_people/state_menu'
require_relative 'extensions/gk_people/sync'
require_relative 'extensions/gk_people/actor'
require_relative 'extensions/gk_people/pin'
require_relative 'extensions/gk_people/responsibilities'
require_relative 'extensions/gk_people/credentials'
require_relative 'extensions/gk_people/role_sync'
require_relative 'extensions/gk_people/import'
require_relative 'extensions/gk_people/company_data'
require_relative 'extensions/gk_people/reading_backfill'
require_relative 'extensions/gk_people/owner'
require_relative 'extensions/gk_people/quick_parse'
require_relative 'extensions/gk_people/verification_places'
require_relative 'extensions/gk_people/quick'
require_relative 'extensions/gk_people/avatars'
require_relative 'extensions/gk_people/avatar_folder'
require_relative 'extensions/gk_people/avatar_icon'
require_relative 'extensions/gk_people/outward'
require_relative 'extensions/gk_people/patches'

Redmine::Plugin.register :gk_people do
  name        'GK People'
  author      'Jimmy Westberg'
  description 'People, organizations and identifiers, with or without a Redmine account'
  version     '1.00.000'
  requires_redmine version_or_higher: '6.0.0'

  settings default: { 'create_person_on_user' => '1', 'match_by_email' => '1', 'elevation_enabled' => '0', 'elevation_minutes' => '15',
                     'elevation_max_minutes' => '120', 'elevation_reserve_owners' => [], 'elevation_reserve_suffix' => '_admin',
                     'elevation_shared_admin' => '0', 'elevation_shared_admin_id' => '', 'actor_group_id' => '', 'actor_minutes' => '10',
                     'credential_warn_days' => '30', 'role_sync_enabled' => '0', 'name_chat_exposure' => 'off',
                     'token_min_length' => '8', 'actor_prolong' => '1', 'own_avatar_for_all' => '1',
                     'avatar_order' => 'own_first', 'avatars_hide_anonymous' => '1', 'names_hide_anonymous' => '0',
                     'data_controller_org_id' => '', 'verification_review_person' => '0',
                     'verification_review_organization' => '0', 'verification_review_group' => '0' }, partial: 'settings/gk_people_settings'

  # The permissions are registered whatever the gate to GK GUI Stuff says (gate.rb): core's role form lists only the
  # permissions that are registered and Role#permissions= writes the whole list, so a role saved while they were away
  # would lose them. With the gate closed they open nothing (the controllers answer 404, the menu rows are gone).
  # Global permissions (people, Behörigheter): granted through a role in any project; an administrator always has them
  permission :gk_people_view, { gk_people_persons: %i[index show identify autocomplete], gk_people_organizations: %i[index show], gk_people_org_kinds: %i[index],
                              gk_people_responsibilities: %i[index show holder], gk_people_credentials: %i[index],
                              gk_people_identifiers: [:index], gk_people_groups: %i[index show members] }, require: :loggedin, global: true
  permission :gk_people_manage, { gk_people_persons: %i[new create edit update link unlink],
                                gk_people_organizations: %i[new create edit update], gk_people_imports: %i[index new create show update run discard template],
                                gk_people_groups: %i[new create edit update add_member remove_member] }, require: :loggedin, global: true
  # Pictures of users: any account's, or only one's own; checked in GkPeople::Avatars.may_edit?
  permission :gk_people_manage_avatars, { gk_people_avatars: %i[edit update remove region original icon hide_folder] }, require: :loggedin, global: true
  permission :gk_people_change_own_avatar, { gk_people_avatars: %i[edit update remove region original icon hide_folder] }, require: :loggedin, global: true
  permission :gk_people_manage_identifiers,{ gk_people_identifiers: %i[create end_identifier] }, require: :loggedin, global: true
  # The integration account: the sync endpoints and their log; nothing else
  permission :gk_people_sync, { gk_people_sync: %i[create index show] }, require: :loggedin, global: true
  # actor_records: who stood at a shared computer, on the issues one may see
  permission :gk_people_view_actor_records, { gk_people_actor: %i[index] }, require: :loggedin, global: true
  # responsibilities: holding, ending and deputies (never one's own); the page and the lookup come with gk_people_view
  permission :gk_people_manage_responsibilities, { gk_people_responsibilities: %i[new create edit update assign end_assignment deputy add_rule remove_rule],
                                                 gk_people_role_sync: %i[index run] },
             require: :loggedin, global: true
  # credentials: adding, correcting and revoking, with the proof uploaded as attachments; the kinds are an admin's
  permission :gk_people_manage_credentials, { gk_people_credentials: %i[new create edit update revoke], attachments: %i[upload] },
             require: :loggedin, global: true
  # OAuth scope for writing the identifier schemes over REST (a role grants nothing with it; who may is still the
  # administrator)
  permission :gk_people_api_schemes, {}, require: :loggedin, global: true

  # One entry in the top menu under a general name; the registers (persons, organizations, groups, organisation,
  # credentials) are reached by the tabs above every list
  menu :top_menu, :gk_people_persons, { controller: 'gk_people_persons', action: 'index' },
       caption: :label_gk_people_menu, after: :projects, if: proc { GkPeople.gui? && GkPeople::Access.view? }
  menu :admin_menu, :gk_people_schemes, { controller: 'gk_people_schemes', action: 'index' },
       caption: :label_gk_people_schemes, icon: 'key', html: { class: 'icon' }, after: :groups, if: proc { GkPeople.gui? && GkPeople.feature?('people.identifiers') }
  menu :admin_menu, :gk_people_credential_kinds, { controller: 'gk_people_credential_kinds', action: 'index' },
       caption: :label_gk_people_credential_kinds, icon: 'checked', html: { class: 'icon' }, after: :gk_people_schemes,
       if: proc { GkPeople.gui? && GkPeople.feature?('people.credentials') }
  menu :admin_menu, :gk_people_org_kinds, { controller: 'gk_people_org_kinds', action: 'index' },
       caption: :label_gk_people_org_kinds, icon: 'group', html: { class: 'icon' }, after: :gk_people_credential_kinds, if: proc { GkPeople.gui? }
  # The list of roles and departments the quick line reads
  menu :admin_menu, :gk_people_quick_words, { controller: 'gk_people_quick', action: 'words' },
       caption: :label_gk_people_quick_words, icon: 'list', html: { class: 'icon' }, after: :gk_people_org_kinds, if: proc { GkPeople.gui? && GkPeople::Quick.on? }
  menu :admin_menu, :gk_people_processing, { controller: 'gk_people_processing', action: 'index' },
       caption: :label_gk_people_processing, icon: 'lock', html: { class: 'icon' }, after: :gk_people_schemes, if: proc { GkPeople.gui? }
  menu :admin_menu, :gk_people_elevations, { controller: 'gk_people_elevations', action: 'index' },
       caption: :label_gk_people_elevations, icon: 'history', html: { class: 'icon' }, after: :gk_people_processing, if: proc { GkPeople.gui? }
  menu :admin_menu, :gk_people_sync_log, { controller: 'gk_people_sync', action: 'index' },
       caption: :label_gk_people_sync_log, icon: 'reload', html: { class: 'icon' }, after: :gk_people_elevations,
       if: proc { GkPeople.gui? && GkPeople.feature?('people.sync') }
  # elevation and Se som in core's account menu after Mitt konto, for an administrator's own account, in the role for
  # what only administrators see; the rows of a state stand only on a phone (GkPeople::StateMenu)
  admin_row = 'gk-gui-stuff-menu-admin'
  phone_row = "#{admin_row} gk-people-menu-phone"
  menu :account_menu, :gk_people_step_up, { controller: 'gk_people_elevations', action: 'new' },
       caption: ->(_p) { GkPeople::StateMenu.step_up_caption }, after: :my_account, icon: 'lock',
       html: { class: "icon gk-people-step-up #{admin_row}" }, if: proc { GkPeople.gui? && GkPeople::StateMenu.step_up? }
  menu :account_menu, :gk_people_cannot_step_up, { controller: 'gk_people_elevations', action: 'new' },
       caption: ->(_p) { GkPeople::StateMenu.cannot_caption }, after: :gk_people_step_up, icon: 'lock',
       html: { class: "icon gk-people-step-up #{phone_row} gk-gui-stuff-menu-off" }, if: proc { GkPeople.gui? && GkPeople::StateMenu.cannot? }
  menu :account_menu, :gk_people_elevated, :gk_people_menu_elevation_path,
       caption: ->(_p) { GkPeople::StateMenu.elevated_caption }, after: :gk_people_cannot_step_up,
       html: { class: phone_row }, if: proc { GkPeople.gui? && GkPeople::StateMenu.elevated? }
  menu :account_menu, :gk_people_step_down, { controller: 'gk_people_elevations', action: 'step_down' },
       caption: :button_gk_people_step_down, after: :gk_people_elevated, html: { method: :post, class: phone_row },
       if: proc { GkPeople.gui? && GkPeople::StateMenu.elevated? }
  menu :account_menu, :gk_people_seeing_as, :gk_people_menu_elevation_path,
       caption: ->(_p) { GkPeople::StateMenu.seeing_caption }, after: :gk_people_step_down,
       html: { class: phone_row }, if: proc { GkPeople.gui? && GkPeople::StateMenu.seeing? }
  menu :account_menu, :gk_people_see_as_stop, :gk_people_menu_see_as_stop_path,
       caption: :button_gk_people_see_as_stop, after: :gk_people_seeing_as, html: { method: :post, class: phone_row },
       if: proc { GkPeople.gui? && GkPeople::StateMenu.seeing? }
  # Se som: look at this page as a person, a group or a role; offered also before stepping up, when the choice says so
  menu :account_menu, :gk_people_see_as, { controller: 'gk_people_see_as', action: 'new' },
       caption: :label_gk_people_see_as_row, after: :gk_people_see_as_stop, html: { class: "gk-people-see-as #{admin_row}" },
       if: proc { GkPeople.gui? && GkPeople::StateMenu.see_as? }
  menu :account_menu, :gk_people_reserve, :gk_people_menu_elevation_path,
       caption: ->(_p) { GkPeople::StateMenu.reserve_caption }, after: :gk_people_see_as,
       html: { class: 'gk-gui-stuff-menu-alarm gk-people-menu-phone' }, if: proc { GkPeople.gui? && GkPeople::StateMenu.reserve? }
end

# Everything below is people at work, in two layers (gate.rb). What protects or writes traces is applied whatever
# the gate to GK GUI Stuff says: the core patches of the protection layer, people's functions in records' register
# and the role sync's job in ops (and records calls register_records! for the targets and the event kinds). What a
# person works with is registered only with the gate open (the blocks under "if gui"). The lines stand in one order
# for both, so that the order with the gate open is the same as before. gate.rb is required above and GK GUI Stuff
# loads before people, so the gate answers here.
gui = GkPeople.gui?

# The record of processing: what people declares for core's tables, its own and records'
GkPeople::Processing.declare_defaults! if gui

# Core patches (extensions/gk_people/patches.rb, listed in plugins/people, Core-patchar), applied here in the one
# order patches.rb gives, and again on every reload. Always: account and membership events, elevation, reserve
# accounts, what those outside see, actor_records and role_sync. Only with GK GUI Stuff: Se som, the helper in every
# view and the chat program's choice.
GkPeople::Patches.install!
if gui
  # elevation's and Se som's bars (core's hooks)
  Redmine::Hook.add_listener(GkPeople::Elevation::Hooks) unless Redmine::Hook.listeners.any?(GkPeople::Elevation::Hooks)
  Redmine::Hook.add_listener(GkPeople::SeeAs::Hooks) unless Redmine::Hook.listeners.any?(GkPeople::SeeAs::Hooks)
  # The person on the account's page and on its admin page (core's hooks, nothing replaced)
  Redmine::Hook.add_listener(GkPeople::Hooks) unless Redmine::Hook.listeners.any?(GkPeople::Hooks)
  # The box Deltagare on a meeting, above records' row of links (core's hook, nothing replaced)
  Redmine::Hook.add_listener(GkPeople::QuickHooks) unless Redmine::Hook.listeners.any?(GkPeople::QuickHooks)
  # actor_records: the field and the lines (hooks)
  Redmine::Hook.add_listener(GkPeople::Actor::Hooks) unless Redmine::Hook.listeners.any?(GkPeople::Actor::Hooks)
  # role_sync's daily run as a job in ops (gk_ops loads first, alphabetically); without ops the fallback in user_setup.
  # Registered only while the function people.responsibilities is on (RoleSync.ops_registrations!, below).
  # role_sync: the project's member list (hooks)
  Redmine::Hook.add_listener(GkPeople::RoleSync::Hooks) unless Redmine::Hook.listeners.any?(GkPeople::RoleSync::Hooks)
  # The group's card for gui_stuff link_preview (gui_stuff loads before people, alphabetically)
  GkPeople::GroupCard.register!
  # The names in people's registers (schemes, groups, responsibilities, kinds, processing) in fields' one place for
  # translations, a row each: the attributes, the label, the records and the page that is off there. fields loads first.
  if defined?(GkFields::Translations) && GkFields::Translations.respond_to?(:register_type)
    { 'GkPeopleScheme' => [%w[name], :label_gk_people_schemes, -> { GkPeopleScheme.sorted }, 'gk_people_schemes'],
      'GkPeopleGroup' => [%w[name description], :label_gk_people_groups, -> { GkPeopleGroup.sorted }, 'gk_people_groups'],
      'GkPeopleResponsibility' => [%w[name description], :label_gk_people_organisation, -> { GkPeopleResponsibility.sorted }, 'gk_people_responsibilities'],
      'GkPeopleOrgKind' => [%w[name description], :label_gk_people_org_kinds, -> { GkPeopleOrgKind.sorted }, 'gk_people_org_kinds'],
      'GkPeopleCredentialKind' => [%w[name description], :label_gk_people_credential_kinds, -> { GkPeopleCredentialKind.sorted }, 'gk_people_credential_kinds'],
      'GkPeopleProcessing' => [%w[purpose retention visible_to], :label_gk_people_processing, -> { GkPeopleProcessing.order(:table_name) }, 'gk_people_processing'] }
      .each do |type, (attrs, label, records, controller)|
        GkFields::Translations.register_type(type, attrs: attrs, label: -> { I18n.t(label) }, records: records, off_controllers: [controller])
      end
  end

  # The chat program's icons after names are people's appearance setting name_chat in records' register (records loads
  # after people, alphabetically)
  Rails.configuration.after_initialize { GkPeople::NameLinks.register! }

  # ops' invariants: asked every hour by ops (people loads after ops, alphabetically). A responsibility in force must
  # have a holder; an active person with an active account must have a language, the account's own or at least one in
  # languages.
  # responsibility_vacant only while people.responsibilities is on (RoleSync.ops_registrations!, below).
  if defined?(GkOps::Invariants)
    GkOps::Invariants.register(:gk_people, 'person_without_language', label_key: :label_gk_people_inv_no_language, rows: lambda {
      u = Rails.application.routes.url_helpers
      persons = GkPeoplePerson.where(active: true).where("COALESCE(#{GkPeoplePerson.table_name}.languages, '') = ''")
                              .joins('INNER JOIN users ON users.id = gk_people_persons.user_id')
                              .where(users: { status: User::STATUS_ACTIVE, type: 'User' }).where("COALESCE(users.language, '') = ''")
                              .order(:id)
      # registered only with the gate open at the start, and the gate does not change while the process runs, so the
      # rows always carry the person's address; not reported at all while the gate is closed
      GkPeople::Gate.rows(persons) { |p| u.gk_people_person_path(p) }
    })
  end

  # The kind of export people writes (the import template), declared in revisions' one rule for names (revisions loads
  # after people, alphabetically)
  Rails.configuration.after_initialize { GkPeople::Import.declare_names! }
  # The name links come with the page (gui_stuff PageData)
  Rails.configuration.after_initialize { GkPeople::NameLinks.register_page_data! }
  # Who is chosen at a shared computer, in gui_stuff's top band
  Rails.configuration.after_initialize { GkPeople::Actor.register_band! }

  # The wave's words for this plugin's buttons that are not a save, known by their address (gui_stuff WaveForms). Kör
  # rollsynk: KÖRS och KLART; Importera: IMPORTERAR och IMPORTERAT.
  Rails.configuration.after_initialize do
    ::GkGuiStuff::WaveForms.register(match: '/gk_people/role_sync(\?|$)', word: :gk_gui_stuff_wave_running, done: :gk_gui_stuff_wave_finished, level: 'running')
    ::GkGuiStuff::WaveForms.register(match: '/gk_people/imports/\\d+/run(\?|$)', word: :gk_gui_stuff_wave_importing, done: :gk_gui_stuff_wave_imported)
  end
end

# Always, whatever the gate says: the role sync and the PIN at a shared computer hang on a function, and a sync
# that is not run leaves roles standing. The page that switches the functions is closed without GK GUI Stuff.
# People's functions in records' register (Administration > Funktioner), all off for a new installation (people loads
# before records, so after initialize). Then the ops job and invariant that follow
# people.responsibilities, asked again from requests so a switch needs no restart.
Rails.configuration.after_initialize do
  if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
    GkPeople::FEATURES.each do |key|
      k = key.tr('.', '_')
      ::GkRecords::Features.register(key, plugin: :gk_people, label: :"label_gk_feature_#{k}",
                                           help: :"text_gk_feature_#{k}")
    end
  end
  GkPeople::RoleSync.ops_registrations!(force: true)
end

if gui
  # People's reason places in records' Administration > Skäl, each with its mode today as the default (records
  # loads after people, alphabetically, so after initialize)
  Rails.configuration.after_initialize do
    if defined?(::GkRecords::Reasons)
      # place => [default mode, only an administrator], in core.rb so that the reason buttons keep the default without records
      GkPeople::REASON_PLACES.each do |place, (mode, admin)|
        ::GkRecords::Reasons.register("people.#{place}", plugin: :gk_people, label: :"label_gk_reason_people_#{place}", default: mode, admin: admin)
      end
    end
  end
  # The person's own page is declared once in gui_stuff's register (GkGuiStuff::Personal), which places it by core's
  # version: Stega upp… and Se som… there are the rows in the account's dropdown on a computer's width, where gui_stuff
  # does not show people's own rows in core's account menu (GkPeople::StateMenu)
  Rails.configuration.after_initialize do
    ::GkGuiStuff::Personal.register('people.step_up', plugin: :gk_people, label: :label_gk_people_step_up_row, order: 80, css: 'gk-people-step-up gk-people-personal',
                                      url: { controller: 'gk_people_elevations', action: 'new' }, if: ->(u) { GkPeople::Elevation.may_step_up?(u) })
    # Att komplettera with the count of one's own quick contacts, waiting
    ::GkGuiStuff::Personal.register('people.to_complete', plugin: :gk_people, label: :label_gk_people_to_complete, order: 40, icon: 'list',
                                      url: { controller: 'gk_people_quick', action: 'index', mine: '1' }, waits: true,
                                      count: ->(u) { GkPeople::Quick.count_mine(u) },
                                      if: ->(u) { GkPeople::Quick.on? && GkPeople::Access.view?(u) })
    ::GkGuiStuff::Personal.register('people.see_as', plugin: :gk_people, label: :label_gk_people_see_as_row, order: 90, css: 'gk-people-see-as gk-people-personal',
                                      url: { controller: 'gk_people_see_as', action: 'new' }, if: ->(u) { GkPeople::SeeAs.may_offer?(u) })
  end
  # The account's own picture first among core's picture sources (core_stuff avatar_sources, or core's register where
  # core has it; core_stuff loads before people, alphabetically)
  Rails.configuration.after_initialize { GkPeople::Avatars.register! }
  # What a review covers on persons and organizations, without people's own columns, and people's places in the
  # verification status with their words and levels (records loads after people)
  Rails.configuration.after_initialize { GkPeople.register_review_content! }
  # A chosen icon from the icon library, between the own picture and the folder's (icons loads before people)
  Rails.configuration.after_initialize { GkPeople::AvatarIcon.register! }
  # The picture from the organization's folder after it (and after a chosen icon), with ops' daily job that removes the
  # pictures of files that are gone (ops loads before people, alphabetically)
  Rails.configuration.after_initialize { GkPeople::AvatarFolder.register! }
  # Every import run before readings existed gets its reading in hindsight, once (records loads after people)
  Rails.configuration.after_initialize { GkPeople::ReadingBackfill.run_once! }
  # Organizations and persons are taggable through tags' register when tags is there (tags loads after this, so after
  # initializing).
  # Their tags are seen by whoever may see the registers and changed by whoever may change them, in the forms; the
  # keys organization and person are what a tag type's allowed_on and required_for name.
  Rails.configuration.after_initialize do
    next unless defined?(::GkTags::Taggables)

    ::GkTags::Taggables.register('GkPeopleOrganization', key: 'organization', label: :label_gk_people_organization,
                                                        view: ->(_o, u) { GkPeople::Access.view?(u) }, tag: ->(_o, u) { GkPeople::Access.manage?(u) },
                                                        url: ->(o) { { controller: 'gk_people_organizations', action: 'show', id: o.id } },
                                                        title: ->(o) { o.name }, controllers: %w[GkPeopleOrganizationsController])
    ::GkTags::Taggables.register('GkPeoplePerson', key: 'person', label: :label_gk_people_person,
                                                  view: ->(_p, u) { GkPeople::Access.view?(u) }, tag: ->(_p, u) { GkPeople::Access.manage?(u) },
                                                  url: ->(p) { { controller: 'gk_people_persons', action: 'show', id: p.id } },
                                                  title: ->(p) { p.name }, controllers: %w[GkPeoplePersonsController])
  end

  # The names in other languages are fields' (Översättningar), like every other name an administrator sets; off where
  # they are written. After every plugin is in, so that the order plugins load in does not matter.
  Rails.configuration.after_initialize do
    if defined?(GkFields::Translations) && GkFields::Translations.respond_to?(:register_type)
      GkFields::Translations.register_type('GkPeopleQuickWord', attrs: %w[name], label: -> { I18n.t(:label_gk_people_quick_words) },
                                           records: -> { GkPeopleQuickWord.order(:id) }, off_controllers: %w[gk_people_quick])
    end
    # The starting kinds and words are named in English by their migrations; their other languages from the locales
    if defined?(GkFields::Translations) && GkFields::Translations.respond_to?(:seed!)
      GkFields::Translations.seed!('GkPeopleOrgKind', label_key_prefix: 'label_gk_people_org_kind_')
      GkPeopleQuickWord.seed_translations!
    end
  end
end
