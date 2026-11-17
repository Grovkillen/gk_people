# frozen_string_literal: true

module GkPeople
  # What the link gives on core's own pages (plugins/people, accounts): the account's page shows the person's
  # organization, title, telephone and channels, and the account's admin page says which person the account
  # belongs to. Both through core's hooks; nothing in core's views is replaced.
  class Hooks < Redmine::Hook::ViewListener
    include GkPeople::Gate::Listener # silent without GK GUI Stuff (gate.rb)
    # Users, the account's page: the person behind it, for those who may see the register (and the person herself)
    def view_account_left_bottom(context = {})
      user = context[:user]
      person = user && GkPeople.person_for(user)
      viewer = User.current
      v = context[:hook_caller]
      # The way to change the account's picture, for one who may
      pic = user && GkPeople::Avatars.may_edit?(user, viewer) ? v.content_tag(:p, v.link_to(l(:label_gk_people_avatar_change), v.gk_people_avatar_edit_path(user_id: user.id), id: 'gk-people-account-avatar')) : ''
      return pic unless person && (GkPeople::Access.view?(viewer) || viewer.id == user.id)

      v.safe_join([v.render(partial: 'gk_people/account_person', locals: { person: person, user: user }), pic])
    end

    # Administration, Users, the account: which person it is, or a way to link one
    def view_users_form(context = {})
      user = context[:user]
      return '' unless user&.persisted? && user.is_a?(::User)

      context[:hook_caller].render(partial: 'gk_people/admin_user_person', locals: { user: user, person: GkPeople.person_for(user) })
    end

    # Names on every page: the chat program behind them (NameLinks), when a scheme is marked for the name's click
    def view_layouts_base_html_head(context = {})
      return '' unless User.current.logged? && GkPeople::NameLinks.any? && GkPeople::NameLinks.on_for?

      v = context[:hook_caller] || context[:controller]&.view_context
      return '' unless v

      # title: the page as a message, from what the page shows (an issue's heading and subject), so that no heading is
      # read back from the page. The account behind a name is the id GK Core Stuff marks on core's link (data-principal-id)
      cfg = { url: v.gk_people_name_links_path,
              title: NameLinks.page_title(v),
              t: { chat_in: l(:text_gk_people_chat_in), copied: l(:text_gk_people_chat_copied) } }
      v.safe_join([v.content_tag('script', ERB::Util.json_escape(cfg.to_json).html_safe, type: 'application/json', id: 'gk-people-names-config'),
                   v.stylesheet_link_tag('gk_people', plugin: 'gk_people'),
                   v.javascript_include_tag('gk_people_names', plugin: 'gk_people')], "\n")
    rescue StandardError => e
      Rails.logger.error("[gk_people] name links not set up: #{e.class}: #{e.message}")
      ''
    end

    # Mitt konto: whether one's own chat link is shown after one's name to others (NameLinks), unless required
    # and one's name hidden from those not signed in, where one's organization allows it
    def view_my_account_preferences(context = {})
      return '' unless User.current.logged?

      v = context[:hook_caller]
      parts = []
      parts << v.render(partial: 'gk_people/my_chat_link', locals: { exposure: GkPeople::NameLinks.exposure }) if GkPeople::NameLinks.schemes.any?
      org = GkPeople.person_for(User.current)&.organization
      parts << v.render(partial: 'gk_people/my_hide_name') if org.respond_to?(:name_hide_allowed) && org.name_hide_allowed
      v.safe_join(parts)
    rescue StandardError => e
      Rails.logger.error("[gk_people] chat link preference not shown: #{e.class}: #{e.message}")
      ''
    end

    # Mitt konto: the way to all one's own data, beside core's own links
    def view_my_account_contextual(context = {})
      v = context[:hook_caller]
      return '' unless v && User.current.logged?

      links = [v.link_to(v.sprite_icon('lock', l(:label_gk_people_my_data)), v.gk_people_my_data_path, class: 'icon icon-lock', id: 'gk-people-my-data')]
      # One's own picture, with Byta egen bild or Hantera bilder på personer
      if GkPeople::Avatars.may_edit?(User.current)
        links << v.link_to(v.sprite_icon('user', l(:label_gk_people_avatar)), v.gk_people_avatar_edit_path(user_id: User.current.id),
                           class: 'icon icon-user', id: 'gk-people-my-avatar')
      end
      v.safe_join(links, ' ')
    rescue StandardError => e
      Rails.logger.error("[gk_people] my data link not shown: #{e.class}: #{e.message}")
      ''
    end
  end
end
