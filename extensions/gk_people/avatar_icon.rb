# frozen_string_literal: true

module GkPeople
  # An icon for any account: a person's, a shared account's or a group's, chosen from the icon
  # library (gk_icons) on the account's picture page. Drawn in a round field of one of eight colours (by the
  # account), the size asked. The source is after an own picture and before the picture folder: an explicit choice
  # before what is fetched. Without the icon library nothing is drawn and the next source answers. Shown by the same
  # rule as the pictures (signed in, may see people and the account).
  module AvatarIcon
    module_function

    SOURCE = 'gk_people_icon_picture'
    POSITION = 20

    def library? = defined?(::GkIcons) && ::GkIcons.respond_to?(:source)

    # A name the library can draw: core's, its own, or a pack's
    def known?(name) = library? && name.present? && !::GkIcons.source(name.to_s).nil?

    # account id => icon name, once per request (nil without RequestStore: asked every time)
    def icons = defined?(::RequestStore) ? (::RequestStore.store[:gk_people_avatar_icons] ||= {}) : nil

    def icon_for(principal)
      memo = icons
      return memo[principal.id] if memo&.key?(principal.id)

      v = ::GkPeopleAvatarIcon.where(user_id: principal.id).pick(:icon)
      memo[principal.id] = v if memo
      v
    end

    def forget(user_id) = icons&.delete(user_id)

    # Sets the icon, or clears it with an empty name; false when the library does not know the name
    def set(principal, name, by: ::User.current)
      forget(principal.id)
      if name.blank?
        ::GkPeopleAvatarIcon.where(user_id: principal.id).delete_all.positive?
      else
        row = ::GkPeopleAvatarIcon.find_or_initialize_by(user_id: principal.id)
        row.assign_attributes(icon: name.to_s.strip, set_by_id: by&.id)
        row.save
      end
    end

    def html(principal, options, view)
      return nil unless library? && principal.is_a?(::Principal) && Avatars.visible?(principal)

      name = icon_for(principal)
      return nil unless name && known?(name)

      size = (options[:size].presence || 50).to_i
      css = (['avatar', 'gk-people-avatar', 'gk-people-avatar-icon'] + options[:class].to_s.split).uniq.join(' ')
      back, fore = COLOURS[principal.id % COLOURS.size]
      look = "display: inline-flex; align-items: center; justify-content: center; inline-size: #{size}px; block-size: #{size}px; " \
             "border-radius: 50%; vertical-align: middle; background: #{back}; color: #{fore};"
      view.content_tag(:span, view.gk_icon(name, nil, size: [(size * 0.6).round, 10].max),
                       class: css, role: 'img', title: options[:title].presence || principal.name, 'aria-label': principal.name,
                       style: look) # gk-u U1: the picture is drawn on every page, where people's stylesheet is not loaded
    end

    # Eight fields, light with dark marks (contrast above 4.5:1): GK GUI Stuff's category roles (the soft tone behind,
    # the role's own as the mark), core's open colour of the same hue as their fallback. Inline, since the picture is
    # drawn on every page and people's stylesheet is not. Written out whole, so that each hex stands as the fallback
    # inside its var().
    COLOURS = [
      ['var(--gk-role-category-1-soft, var(--oc-blue-1, #d0ebff))', 'var(--gk-role-category-1, var(--oc-blue-9, #1864ab))'],
      ['var(--gk-role-category-2-soft, var(--oc-teal-1, #c3fae8))', 'var(--gk-role-category-2, var(--oc-teal-9, #087f5b))'],
      ['var(--gk-role-category-3-soft, var(--oc-grape-1, #eebefa))', 'var(--gk-role-category-3, var(--oc-grape-9, #862e9c))'],
      ['var(--gk-role-category-10-soft, var(--oc-orange-1, #ffe8cc))', 'var(--gk-role-category-10, var(--oc-orange-9, #d9480f))'],
      ['var(--gk-role-category-9-soft, var(--oc-indigo-1, #dbe4ff))', 'var(--gk-role-category-9, var(--oc-indigo-9, #364fc7))'],
      ['var(--gk-role-category-8-soft, var(--oc-green-1, #d3f9d8))', 'var(--gk-role-category-8, var(--oc-green-9, #2b8a3e))'],
      ['var(--gk-role-category-5-soft, var(--oc-pink-1, #ffdeeb))', 'var(--gk-role-category-5, var(--oc-pink-9, #a61e4d))'],
      ['var(--gk-role-category-6-soft, var(--oc-cyan-1, #c5f6fa))', 'var(--gk-role-category-6, var(--oc-cyan-9, #0b7285))']
    ].freeze

    def register!
      reg = if defined?(::Redmine::AvatarSources) then ::Redmine::AvatarSources
            elsif defined?(::GkCoreStuff::AvatarSources) then ::GkCoreStuff::AvatarSources
            end
      reg&.register(SOURCE, position: POSITION) { |principal, options, view| html(principal, options, view) }
    end
  end
end
