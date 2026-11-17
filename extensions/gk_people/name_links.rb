# frozen_string_literal: true

module GkPeople
  # The chat program's icon after a person's name opens the program the person is reached in.
  # General: any contact scheme the administrator marks with the place "name" (Klick på namnet) and a link template
  # is the chat program; its icon is the scheme's icon (Tabler's brand icons in gk_icons, e.g. brand-teams,
  # brand-slack). The person's identifier under that scheme goes into the template with the page's title and address
  # ({message}, {title}, {url}). A program that cannot take a message along (Slack) gets the page's address copied
  # instead. The name stays core's link to the account. Nothing is shown for one's own name.
  module NameLinks
    PLACE = 'name'

    module_function

    # Shown at all: people's appearance setting name_chat in records' register, off (a new installation), optional
    # (each person may switch it off) or forced, as the administrator chooses. Without records the icons are not shown.
    APPEARANCE = 'people.name_chat'

    def on_for?(user = ::User.current)
      defined?(::GkRecords::AppearanceSettings) ? ::GkRecords::AppearanceSettings.on_for?(APPEARANCE, user) : false
    end

    # The appearance setting in records' register (records loads after people: called once every plugin has loaded,
    # and again after a reload); PreferencePatch is prepended with the other core patches (Patches.install!)
    def register!
      return unless defined?(::GkRecords::AppearanceSettings)

      ::GkRecords::AppearanceSettings.register(APPEARANCE, plugin: :gk_people, group: :text,
                                                           label: :label_gk_people_appearance_name_chat, help: :text_gk_people_appearance_name_chat,
                                                           related: %w[gui_stuff.user_status])
    end

    # The person's own link exposed to others: the administrator sets name_chat_exposure to off (no one's link is
    # exposed), optional (each person chooses under Mitt konto, exposed by default) or forced (everyone's is exposed).
    # The viewer's choice is the appearance setting people.name_chat.
    EXPOSURE = %w[off optional forced].freeze

    # A scenario check sets the administrator's choice for its own thread only. Writing and restoring
    # Setting.plugin_gk_people from a check was not safe: core's settings cache is one hash shared by the process's
    # threads, filled with ||= and cleared once per request, so a request running beside the check could put the forced
    # value back into the cache after the check had restored the setting, and the next check's snapshot then wrote it
    # back for good.
    OVERRIDE = :gk_people_name_chat_exposure

    def with_exposure(value)
      before = Thread.current[OVERRIDE]
      Thread.current[OVERRIDE] = value.to_s
      yield
    ensure
      Thread.current[OVERRIDE] = before
    end

    def exposure
      o = Thread.current[OVERRIDE]
      return o if o && EXPOSURE.include?(o)

      s = ::Setting.plugin_gk_people || {}
      v = s['name_chat_exposure'].to_s
      return v if EXPOSURE.include?(v)

      s['name_chat_required'].to_s == '1' ? 'forced' : 'optional'
    end

    def required? = exposure == 'forced'

    def hidden_by?(user)
      case exposure
      when 'off' then true
      when 'forced' then false
      else !user.is_a?(::User) || user.pref[:gk_people_hide_chat].to_s == '1'
      end
    end

    module PreferencePatch
      def self.prepended(base)
        base.safe_attributes 'gk_people_hide_chat'
      end

      def gk_people_hide_chat = (self[:gk_people_hide_chat] || '0')
      def gk_people_hide_chat=(v)
        self[:gk_people_hide_chat] = v.to_s == '1' ? '1' : '0'
      end
    end

    def schemes = ::GkPeopleScheme.active.where(kind: 'contact').sorted.to_a.select { |s| s.shown_on?(PLACE) && s.link_template.present? }
    def any? = exposure != 'off' && schemes.any?

    # Whether the program's link carries the page along; otherwise the address is copied
    def carries_page?(template) = template.to_s.match?(/\{(message|url|title)\}/)

    # user_id => { href:, icon:, app:, copy: } for the accounts the viewer may see, the first marked scheme the
    # person has an identifier in force under
    def for(viewer, ids, context = {})
      return {} unless viewer&.logged? && any? && on_for?(viewer)

      wanted = Array(ids).map(&:to_i).uniq.reject { |i| i.zero? || i == viewer.id }.first(200)
      users = ::User.visible(viewer).active.where(id: wanted).to_a
      users.each_with_object({}) do |u, out|
        next if hidden_by?(u)

        ch = GkPeople.channels_for(u, context, place: PLACE).first
        next unless ch

        scheme = ::GkPeopleScheme.find_by(key: ch[:scheme])
        out[u.id] = { href: ch[:href], icon: ch[:icon], app: ch[:label], copy: !carries_page?(scheme&.link_template) }
      end
    end
  end
end

module GkPeople
  module NameLinks
    # The links for the people the page was drawn with come with the page (gui_stuff PageData); the script asks
    # only for names that came later. The page's title is the issue's number and subject on an issue, as the
    # script made it, else the page's title.
    def self.register_page_data!
      ::GkGuiStuff::PageData.register('people_name_links', plugin: :gk_people) do |ctx|
        viewer = ::User.current
        next nil unless viewer.logged? && any? && on_for?(viewer) && ctx[:users].any?

        url = ctx[:request]&.original_url.to_s.split('#').first.to_s
        links = self.for(viewer, ctx[:users], title: page_title(ctx[:view], ctx[:controller]).to_s, url: url)
        { users: links.transform_keys(&:to_s), asked: ctx[:users].map(&:to_s) }
      end
    end

    # The page as a message, from what the server drew: on an issue its heading (core's issue_heading: tracker and
    # number) and subject, else the page's title (core's html_title parts); nil when there is none. Also given to the
    # script (gk-people-names-config), which then reads no heading back from the page.
    def self.page_title(view, controller = nil)
      controller ||= view.respond_to?(:controller) ? view.controller : nil
      issue = controller.is_a?(::IssuesController) && controller.action_name == 'show' ? controller.instance_variable_get(:@issue) : nil
      title = if issue.is_a?(::Issue)
                "#{issue.tracker&.name} ##{issue.id}: #{issue.subject}"
              else
                Array(view&.instance_variable_get(:@html_title)).reject(&:blank?).join(' - ')
              end
      title.presence&.truncate(200)
    end
  end
end
