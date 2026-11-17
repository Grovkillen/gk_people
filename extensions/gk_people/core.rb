# frozen_string_literal: true

require 'digest'
require 'erb'

# gk_people, the parts that need no Rails (test/core_test.rb runs them with plain ruby): the fixed lists, how a
# channel link is filled, how a token is kept (never in clear text) and how a person's name is made.
module GkPeople
  APPROVAL = %w[not_assessed approved conditional blocked].freeze
  PERSON_KINDS = %w[internal external].freeze
  SCHEME_KINDS = %w[contact reference token].freeze
  SHOW_ON = %w[person account card mention agent name].freeze
  KEY_FORMAT = /\A[a-z][a-z0-9_]{1,59}\z/
  PLACEHOLDERS = %w[value title url message].freeze

  # Declared functions in records' register: every one of them is off until switched on, and off without records.
  # Never asked by a model: the data stays and works again when the function is switched on.
  FEATURES = %w[people.approval people.groups people.identifiers people.group_page people.sync people.pin
                people.responsibilities people.credentials people.quick people.avatars].freeze

  # GK Records' answer, also while the gate to GK GUI Stuff is closed (gate.rb): the role sync and the PIN at a shared
  # computer hang on a function. What draws for a function asks the gate itself.
  def self.feature?(key) = defined?(::GkRecords::Features) ? ::GkRecords::Features.on?(key) : false

  # People's reason places in records' Administration > Skäl: place => [default mode, only an administrator]. Each
  # default is the mode the place had before records knew it, so nothing changes until the administrator changes it.
  REASON_PLACES = { 'relation_new' => [:optional, false], 'relation_end' => [:required, false], 'consent_revoke' => [:optional, false],
                    'credential_revoke' => [:required, false], 'account_link' => [:optional, false], 'account_unlink' => [:optional, true],
                    'identifier_end' => [:optional, false], 'elevation' => [:optional, true], 'see_as' => [:optional, true] }.freeze

  # The reason: of GK GUI Stuff's button with a reason (gk_gui_stuff_reason_button) at one of people's places: the
  # place's key, whose mode records' register decides; without records the place's default, the mode its controller
  # keeps then (a reason required when revoking a credential and ending a relation, else optional)
  def self.reason(place)
    defined?(::GkRecords::Reasons) ? "people.#{place}" : REASON_PLACES.fetch(place.to_s).first
  end

  module Channel
    module_function

    # A scheme's link template with the identifier and the page's context: {value}, {title}, {url} and {message}
    # (the page's title and address as a ready message). Every value is escaped for a URL; a template that is not
    # a link (no scheme such as https: mailto: tel: msteams:) gives nil, so nothing but a link is ever rendered.
    def link(template, value, context = {})
      t = template.to_s.strip
      return nil if t.empty? || value.to_s.strip.empty?
      return nil unless t.match?(/\A[a-z][a-z0-9+.-]*:/i)
      return nil if t.match?(/\A(javascript|data|vbscript):/i)

      values = { 'title' => context[:title].to_s, 'url' => context[:url].to_s,
                 'message' => [context[:title], context[:url]].map(&:to_s).reject(&:empty?).join(' ') }
      t.gsub(/\{(#{PLACEHOLDERS.join('|')})\}/) do
        key = Regexp.last_match(1)
        key == 'value' ? value_part(t, value) : ERB::Util.url_encode(values[key])
      end
    end

    # The identifier in the link: a telephone number as digits and a leading plus (what a dialler reads), an
    # address with its @ kept; everything else escaped
    def value_part(template, value)
      v = value.to_s.strip
      return v.gsub(/[^0-9+]/, '').sub(/(?!\A)\+/, '') if template.match?(/\Atel:/i)

      ERB::Util.url_encode(v).gsub('%40', '@')
    end
  end

  module Token
    module_function

    def digest(value) = Digest::SHA256.hexdigest(value.to_s.strip)

    # What is shown and kept of a token: dots and the last two characters, never more than half of it
    def mask(value)
      v = value.to_s.strip
      return '' if v.empty?

      shown = [2, v.length / 2].min
      ('•' * 6) + v[-shown, shown].to_s
    end

    # The shortest token value a token scheme takes (the setting token_min_length; 8 when empty or not a number)
    MIN_LENGTH = 8
    def min_length(value)
      m = value.to_s.strip
      m.match?(/\A\d+\z/) && m.to_i.positive? ? [m.to_i, 300].min : MIN_LENGTH
    end

    def long_enough?(value, min) = value.to_s.strip.length >= min.to_i
  end

  module Name
    module_function

    # The name a person is shown with: the display name when given, else first and last name
    def of(display_name, first_name, last_name)
      d = display_name.to_s.strip
      return d unless d.empty?

      [first_name, last_name].map { |s| s.to_s.strip }.reject(&:empty?).join(' ')
    end
  end

  # Personal data in the instance's tables. What a column is, by its name: a person (person_id and *_person_id), an
  # account (user_id, author_id, assigned_to_id, *_by_id and the like), or neither. The names are core's and the
  # plugins' own conventions; a table nobody declared is shown as lacking a purpose, which is what the record is
  # for.
  module Privacy
    LEGAL_BASES = %w[contract legal_obligation legitimate_interests consent public_task vital_interests].freeze
    USER_COLUMNS = %w[user_id author_id assigned_to_id principal_id acting_user_id resource_owner_id].freeze
    ROWS_SHOWN = 100
    TEXT_SHOWN = 300

    module_function

    def column_kind(name)
      n = name.to_s
      return :person if n == 'person_id' || n.end_with?('_person_id')
      return :user if USER_COLUMNS.include?(n) || n.end_with?('_by_id') || n.end_with?('_user_id')

      nil
    end

    # Never shown in an extract, not even to the person herself: what lets someone act as her
    def secret?(table, column)
      c = column.to_s
      return true if c.match?(/password|salt|digest|totp|secret|api_key|crypted/)

      %w[tokens oauth_access_tokens oauth_access_grants].include?(table.to_s) && %w[value token refresh_token].include?(c)
    end

    # Who keeps the table: core, or the plugin its prefix names (gk_people_ is people, gk_records_ records)
    PREFIXES = { 'gk_people_' => 'gk_people', 'gk_records_' => 'gk_records' }.freeze
    def owner(table)
      t = table.to_s
      PREFIXES.each { |pre, plugin| return plugin if t.start_with?(pre) }
      return "gk_#{t.split('_')[1]}" if t.start_with?('gk_')

      'core'
    end

    # A value as the extract shows it: a long text shortened, a secret hidden, bytes (a picture) as their size
    def shown(table, column, value)
      return nil if value.nil?
      return :secret if secret?(table, column)
      return "[#{value.bytesize} B]" if value.is_a?(String) && value.encoding == Encoding::BINARY

      v = value.to_s
      v.length > TEXT_SHOWN ? "#{v[0, TEXT_SHOWN]}…" : v
    end
  end

  # SQL that works on every database Redmine runs on: searches through Arel, never ILIKE,
  # concat_ws or a regular expression in the database. Arel's matches is ILIKE on PostgreSQL and LIKE elsewhere
  # (without regard to case there by the column's collation); Concat is || or CONCAT() as the database says.
  module Sql
    module_function

    # node LIKE '%term%', the term's own % and _ taken as they are
    def like(node, term) = node.matches("%#{::ActiveRecord::Base.sanitize_sql_like(term.to_s.strip)}%")

    def text(value) = ::Arel::Nodes.build_quoted(value.to_s)
    def coalesce(node) = ::Arel::Nodes::NamedFunction.new('COALESCE', [node, text('')])
    def concat(*nodes) = nodes.reduce { |a, b| ::Arel::Nodes::Concat.new(a, b) }

    # A person's name parts in one text, as concat_ws(' ', display_name, first_name, last_name) gave it
    def full_name(table) = concat(coalesce(table[:display_name]), text(' '), coalesce(table[:first_name]), text(' '), coalesce(table[:last_name]))
  end

  # elevation's window: open for so many minutes after the last request, never past the maximum from the start
  module Window
    module_function

    def expires_at(started_at, now, minutes, max_minutes) = [now + (minutes * 60), started_at + (max_minutes * 60)].min

    # A setting in minutes: a whole number above zero, else the default
    def minutes(value, default)
      m = value.to_s.strip
      m.match?(/\A\d+\z/) && m.to_i.positive? ? m.to_i : default
    end
  end

  # Stepping up after wrong passwords: after five in a row for the same account each further try waits 30, 60,
  # then 120 seconds (the ceiling) from the last wrong one
  module Backoff
    module_function

    FREE = 5
    FIRST = 30
    CEILING = 120

    def delay(failures)
      n = failures.to_i
      return 0 if n < FREE

      [FIRST * (2**[n - FREE, 3].min), CEILING].min
    end

    # Whole seconds still to wait (0 when a try may be made); last_at and now are Times or numbers of seconds
    def remaining(failures, last_at, now)
      d = delay(failures)
      return 0 if d.zero? || last_at.nil?

      [(last_at.to_f + d - now.to_f).ceil, 0].max
    end
  end

  # The reasons offered when stepping up: the given lists in order, each reason once whatever its case or spacing
  module Reasons
    module_function

    def pick(*lists, limit)
      seen = {}
      lists.flatten.each_with_object([]) do |r, out|
        t = r.to_s.strip.gsub(/\s+/, ' ')
        k = t.downcase
        next if t.empty? || seen[k]

        seen[k] = true
        out << t
        break out if out.size >= limit
      end
    end
  end

  # The switch for elevation outside the web: off when the first word of the text is off (any case); anything else,
  # or nothing, leaves it to the setting
  module Switch
    module_function

    def off?(text) = text.to_s.sub(/\A\uFEFF/, '').strip.split(/\s+/).first.to_s.casecmp?('off')
  end

  # Where a Back or Cancel goes. The check is always core's: the caller passes what its validate_back_url (controller
  # or view, both have it) gave, so a stricter core check reaches people as it is. Here only people's own refusals
  # on top: a path under a prefix (Vem \u00E4r du? and its PIN would ask again) or the page itself (a question would
  # come back to itself). The prefix is taken from the caller's route helper, so a sub-URI install holds.
  module BackUrl
    module_function

    # max: the longest address kept; a longer one is refused whole, never cut (a cut one is not what core checked)
    def pick(validated, not_under: nil, not_path: nil, max: nil)
      return nil unless validated.is_a?(String) && !validated.empty?
      return nil if max && validated.length > max

      path = validated.split(/[?#]/, 2).first.to_s
      return nil if not_path && path == not_path
      return nil if not_under && (path == not_under || path.start_with?("#{not_under}/"))

      validated
    end
  end

  # Reserve accounts: the login a personal one gets, and the file that opens them outside the web
  module ReserveName
    LOGIN = /\A[a-z0-9_\-@.]+\z/i
    SUFFIX = /\A[a-z0-9_\-.]{1,20}\z/i
    DEFAULT_SUFFIX = '_admin'

    module_function

    # The suffix from the settings: letters, digits, _ - . (1 to 20); anything else gives the default
    def suffix(value)
      v = value.to_s.strip
      v.match?(SUFFIX) ? v : DEFAULT_SUFFIX
    end

    # <login><suffix>, or nil when it would not be a valid Redmine login (format, at most 60 characters)
    def login(owner_login, suffix)
      l = "#{owner_login}#{suffix}"
      l.length <= 60 && l.match?(LOGIN) ? l : nil
    end

    # An address that never receives mail: Redmine wants one, unique, per account
    def mail(login) = "#{login.downcase.gsub(/[^a-z0-9._-]/, '-')}@reserv.invalid"
  end

  # control/reserve.txt: one line per account to open, the rest stay locked. "open <login> <minutes>" (or oppna,
  # öppna), where the login is the reserve account's, its owner's, or shared; minutes from the file's own time,
  # 60 if left out, at most a day. # starts a comment. The file is a state, not a command: delete the line or the
  # file, or let the time pass, and the account is locked again.
  module Unlock
    WORDS = %w[open oppna öppna].freeze
    MAX_MINUTES = 24 * 60

    module_function

    # { login (downcased) => open until }
    def parse(text, written_at)
      text.to_s.sub(/\A\uFEFF/, '').each_line.each_with_object({}) do |line, h|
        words = line.sub(/#.*/, '').strip.split(/\s+/)
        next unless words.size >= 2 && WORDS.include?(words[0].downcase)

        minutes = words[2].to_s.match?(/\A\d+\z/) ? words[2].to_i : 60
        minutes = minutes.clamp(1, MAX_MINUTES)
        until_at = written_at + (minutes * 60)
        key = words[1].downcase
        h[key] = until_at if h[key].nil? || until_at > h[key]
      end
    end
  end

  # Se som (SeeAs): what the state's box says about the place, and the pages never shown as someone else. Plain Ruby,
  # tested in test/core_test.rb.
  module SeeAsPlace
    # Pages that show someone's secrets (API and RSS keys, two-factor and its backup codes): refused under Se som
    BLOCKED = { 'my' => %w[show_api_key api_key reset_api_key rss_key reset_rss_key reset_atom_key], 'twofa' => :all,
                'twofa_backup_codes' => :all, 'sys' => :all, 'mail_handler' => :all }.freeze

    module_function

    # nil when nothing needs saying; :not_member (the person or group is not in this project), :role_elsewhere (the
    # role is looked at in another project, so here as a non-member), :role_missing (nobody has the role in this
    # project, so it is seen as by a non-member)
    def notice(kind:, here:, member_here: true, role_project: nil, role_used: true)
      return nil if here.nil?
      return (member_here ? nil : :not_member) unless kind == 'role'
      return :role_elsewhere if role_project != here

      role_used ? nil : :role_missing
    end

    def blocked?(controller, action)
      v = BLOCKED[controller.to_s]
      v == :all || (v.is_a?(Array) && v.include?(action.to_s))
    end
  end

  # A value against a scheme's format (a regular expression, anchored as a whole); a broken format never accepts
  FORMAT_TIMEOUT = 1.0
  def self.format_ok?(format, value)
    f = format.to_s.strip
    return true if f.empty?

    # an administrator's free expression: at most a second per value (catastrophic backtracking), else no match
    Regexp.new("\\A(?:#{f})\\z", timeout: FORMAT_TIMEOUT).match?(value.to_s.strip)
  rescue Regexp::TimeoutError, RegexpError
    false
  end
end
