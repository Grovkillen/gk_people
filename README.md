# GK People

GK People keeps registers of people, organizations and identifiers in Redmine, with or without a Redmine account. A person can be linked to an account, and around the registers the plugin adds groups of people, responsibilities, credentials, personal data records and safer administrator work.

## Features

Registers:

- People and organizations as registers of their own, reached from the top menu (Directory, with a tab for each register), with REST endpoints. A person can exist without a Redmine account; nothing is deleted, posts are made inactive.
- Linking a person and an account (at most one each way): by hand on the person page or the account's administration page, by matching e-mail when an account is made, or by creating a person for every new account. The account page shows the person's organization, title, telephone and channels.
- Account events: account created, registered, activated, locked, unlocked and deleted, and project memberships added, removed and changed, caught from the models so changes from the API, LDAP or a sync are included.
- Kinds of organization, parent organizations, relations between organizations (ended, never deleted), and approval and risk class for organizations.
- Consents on persons, with purpose and period; revoked, never deleted.
- Identifiers and contact channels per person under schemes defined in Administration > Identifiers. A scheme can carry a link template, and a chat program scheme puts its icon after a person's name to open a chat with the page's title and address.
- Groups of people (separate from Redmine's groups) with members, and a group page for Redmine's own groups that shows what the group does, its authority and its history.
- One organization can be marked as the installation's owner (for every language or chosen ones); other plugins read its details, for example for file names.
- Import of organizations or persons from CSV in two steps (preview, then run), matching organizations on organization number and persons on e-mail, never on a name, with modes Fill empty fields, Overwrite and Skip. Templates can be downloaded.
- Sync endpoints for an integration account: idempotent upsert of organizations, persons and groups from an external system, matched on source and external id, with a log under Administration > Sync (people). Fields owned by the source are locked locally.
- Quick contacts: a person or organization written on one line (name, e-mail, telephone, organization, role) is saved as an incomplete post, listed under "To complete", and finished with Done, merged with an existing post, or marked as different. Shown as a Participants box on meetings and a Contacts box on organization pages. Roles and departments for reading the line are set in Administration > Roles and departments.

Organisation and credentials:

- Responsibilities with assignments in a scope (the whole organization, a group of people or a project), dates and a deputy who stands in when the holder's account is locked or during a set period. Shown on the Organisation page and the person page.
- Roles from responsibilities: Redmine roles given and removed automatically from responsibility rules (in the assignment's project, a named project, or every project of a project type), when something changes, by hand and once a day. Roles removed by hand are shown as deviations.
- Credentials and training of persons and organizations, with kinds (Administration > Credential kinds), validity, issuer, number and proof as attachments; statuses valid, expiring, not yet, expired and revoked. A responsibility can require credential kinds.

Personal data:

- Administration > Personal data: a record of processing listing every table in the instance that holds a person or an account, found in the database itself, with purpose, legal basis, retention and who sees it.
- A subject access extract per person, and "My personal data" under My account for each user's own data.

Administrator safety:

- Elevation (optional): administrators work without administrator rights and step up when needed, with the password again, an optional reason and a time that is extended while they work. Everything changed meanwhile is kept with the elevation (Administration > Elevations).
- Reserve accounts for chosen administrators, locked by default and opened only from the server through a control file, so administration stays reachable if elevation fails. An optional shared administrator account can be chosen.
- See as: an administrator who has stepped up can view pages as a person, a group or a role in a project would see them. Read only: every request is rolled back, no mail is sent, and pages with secrets are refused.

Shared computers:

- Accounts in a chosen Redmine group are shared accounts. At a shared computer the person says who they are (by search, badge or card, optionally with a PIN) and what they may do follows a matrix of people and roles on the account. The person is recorded beside issues, notes and time entries as "Registered via shared accounts", and the choice ends after a set idle time.
- PINs are set by each person under My account or given by an administrator as a start code; they are stored hashed (PBKDF2) and locked for 15 minutes after five wrong attempts.

With gk_records, changes to the registers are kept as events, notes and links, with reason fields.

## Requirements

- Redmine 6.0.0 or higher.
- Ruby 3.2 or later, the version your Redmine release runs on.
- PostgreSQL. Times are stored with their time zone (`timestamptz`), which the plugin relies on.

This plugin is developed and tested on Windows 11 with PostgreSQL only. That is a deliberate choice made for the maintainer's own convenience: the production system and the whole toolchain run there, and supporting other platforms and databases would cost time without adding anything for our own use. Times are stored with their time zone (`timestamptz`), so PostgreSQL is required. Apart from that, the Ruby code avoids needless Windows or PostgreSQL specific constructs, so it may well run on Linux, but that is untested and not supported.

GK plugins:

- Required:
  - gk_gui_stuff: the top band, where who is at a shared computer stands as a part with its panel; the page Administration > Functions where the switchable functions are switched on, personal pages, link preview cards, the chat icon module and every button, box and list the plugin draws. Without it (missing, too old or not active) the pages, the menus, what GK People draws on other pages and the API are closed. Protection and traces hold all the same: the registered permissions, the account, membership and group events in gk_records, reserve accounts, hidden names for visitors who are not signed in and roles from responsibilities. Elevation cannot ask for the step up then, so administrators keep their administrator rights; each such session is recorded as an elevation with the method Gate closed, with what was changed and an event on the account. A shared account cannot be used meanwhile. The plugin's settings page says what is missing, and the database migrations still run.
- Optional:
  - gk_records: events, notes, links, readings, verification status, merging quick contacts, reason fields and the register of the switchable functions; without it no history is kept, those parts are not shown and every switchable function is off.
  - gk_fields: translated names; without it names are shown as written.
  - gk_ops: roles from responsibilities as a daily job and health checks; without it the daily run happens at the first web request after midnight.
  - gk_project_types: role rules per project type and the quick contacts box on meetings.
  - gk_revisions: the file name of the import template.
  - gk_tags: tags on organizations and persons.
  - gk_icons: icons for chat links.
  - gk_core_stuff: the mark `data-principal-id` on Redmine's name links (module principal_marks), by which the chat icon after a name knows the account; without it no name gets a chat icon.
  - gk_compat: core's colour variables on Redmine 6.0 and 6.1, and account events when several accounts are locked at once on Redmine 6.0.
  - gk_scenarios: the plugin's scenario steps and checks.

## Installation

The plugin directory must be named `gk_people` (it is the plugin id): `plugins/gk_people/`.

1. Unpack the release package into Redmine's `plugins` directory.
2. Run the migrations: `bundle exec rake redmine:plugins:migrate RAILS_ENV=production`
3. Restart Redmine.

Uninstall:

1. `bundle exec rake redmine:plugins:migrate NAME=gk_people VERSION=0 RAILS_ENV=production`
2. Remove the `plugins/gk_people` directory and restart Redmine.

## Configuration

- Administration > Plugins > Configure (GK People): accounts (create a person for new accounts, match by e-mail, accounts without a person), elevation (on or off, minutes, maximum minutes), reserve accounts (owners, suffix, shared administrator account), shared accounts (group, how long the chosen person holds, extending without a new PIN, shortest badge value), the warning days for credentials, roles from responsibilities, and exposure of the chat link.
- Administration: Identifiers, Credential kinds, Kinds of organization, Roles and departments, Personal data, Elevations and Sync (people).
- Administration > Roles and permissions: global permissions to view and manage people, organizations and groups of people, manage identifiers, sync, view who registered via shared accounts, manage responsibilities and manage credentials.
- With gk_records and gk_gui_stuff, Administration > Functions switches Approval and risk class, Groups of people, Identifiers, Group page with description, Sync (people), PIN for shared computers, Organisation and responsibilities, Credentials, Quick contacts and Pictures of users. All are off in a new installation.

## Usage

- Directory in the top menu, for users with the view permission; the registers are tabs on its pages.
- My account: "My personal data", and the PIN when shared computers are used.
- Administrators who may step up find Step up… and See as… in the account menu after My account (with gk_gui_stuff in the account's dropdown on Redmine 7.0). While stepped up or seeing as, the state stands in the top menu with a small box and a ribbon; on a phone the rows under Account follow the state.
- On a shared computer, "Who are you?" appears before the first page.

## Changelog

See CHANGELOG.md.

## License

GPL-2.0-or-later, the same license as Redmine. Copyright (C) 2026 Jimmy Westberg. See the LICENSE file for the full text.
