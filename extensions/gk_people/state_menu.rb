# frozen_string_literal: true

module GkPeople
  # The rows of elevation and Se som in core's account menu, for an administrator's own account. Each row carries
  # gui_stuff's class for what only administrators see (gk-gui-stuff-menu-admin), so the same rows serve every series:
  # * where the account is links in the top menu, Stega upp… and Se som… stand as links after Mitt konto;
  # * on a phone core moves the account menu under Konto in its menu with three bars, and there the rows follow the
  #   state: stepped up gives "Administratör till 14:32" and Stega ner; one who cannot step up sees Stega upp… dimmed
  #   with the reason; seeing as gives "Ser som Anna Berg" and Sluta se som; the reserve account gets its row in the
  #   alarm role;
  # * the rows of a state (gk-people-menu-phone) stand only on a phone: on a computer's width the state is the line in
  #   the top menu with its box (gk_people_elevations/_menu, gk_people_see_as/_menu) and gui_stuff's ribbon.
  # Where the account is a dropdown, gui_stuff does not show these rows there on a computer's width; Stega upp… and Se
  # som… are then gui_stuff's personal pages in the dropdown (init.rb), whose copy is not shown again on a phone.
  module StateMenu
    extend Redmine::I18n

    class << self
      def h = ActionController::Base.helpers

      # Any error in a condition hides the row, never the page
      def guard
        yield ? true : false
      rescue StandardError => e
        Rails.logger.warn("[gk_people] account menu row not shown: #{e.class}: #{e.message}")
        false
      end

      def mine? = Elevation.governs?(::User.current)
      def step_up? = guard { Elevation.may_step_up? }
      def cannot? = guard { Elevation.lacks_person? && !Elevation.reserve_session? }
      def elevated? = guard { mine? && Elevation.elevated? && !Elevation.reserve_session? }
      def reserve? = guard { mine? && Elevation.reserve_session? }
      def seeing? = guard { SeeAs.active? }
      def see_as? = guard { SeeAs.may_offer? }

      def step_up_caption = l(:label_gk_people_step_up_row)

      def cannot_caption
        h.safe_join([l(:label_gk_people_step_up_row), h.content_tag(:small, l(:text_gk_people_cannot_step_up_why))])
      end

      def elevated_caption
        e = Elevation.current
        e ? h.content_tag(:strong, l(:text_gk_people_elevated_until, until: format_time(e.expires_at, false))) : ''
      end

      def reserve_caption
        h.safe_join([h.content_tag(:strong, l(:label_gk_people_reserve_row)), h.content_tag(:small, l(:text_gk_people_reserve_row))])
      end

      def seeing_caption = h.content_tag(:strong, l(:text_gk_people_see_as_menu, who: SeeAs.record&.ribbon_who.to_s))
    end
  end
end
