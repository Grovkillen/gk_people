# frozen_string_literal: true

module GkPeople
  # What those outside see of a person. Settings of people's (the administrator):
  #   avatar_order            own_first (default): an own picture before the organization's folder picture;
  #                           folder_first: the folder's picture first, the own one only when the folder has none
  #   avatars_hide_anonymous  '1' (default): no picture of people's for one not signed in; '0': core's rule for who
  #                           sees which account decides (User.visible)
  #   names_hide_anonymous    '0' (default); '1': one not signed in sees title and organization instead of a name
  # And per organization (its picture folder's or the person's own): avatar_hide_allowed lets a person hide the
  # folder's picture (the next source shows; the file stays), name_hide_allowed lets a person hide the name from those
  # not signed in. The person's choices are preferences of the account (gk_people_hide_folder_picture,
  # gk_people_hide_name), set on the picture page and on My account.
  # A name is changed only while a web page is drawn for one not signed in (with_request), never in a mail.
  module Outward
    module_function

    ORDERS = %w[own_first folder_first].freeze

    def setting(key, default) = ((::Setting.plugin_gk_people || {})[key.to_s].presence || default).to_s
    def folder_first? = setting('avatar_order', 'own_first') == 'folder_first'
    def hide_pictures_for_anonymous? = setting('avatars_hide_anonymous', '1') != '0'
    def hide_names_for_anonymous? = setting('names_hide_anonymous', '0') == '1'

    # The person behind an account and the organization whose allowances count: the person's own
    def person(user) = user.is_a?(::User) ? GkPeople.person_for(user) : nil

    def folder_picture_hidden?(user, org)
      user.is_a?(::User) && org&.respond_to?(:avatar_hide_allowed) && org.avatar_hide_allowed && user.pref[:gk_people_hide_folder_picture].to_s == '1'
    end

    def name_hidden_by_choice?(user)
      return false unless user.is_a?(::User) && user.pref[:gk_people_hide_name].to_s == '1'

      org = person(user)&.organization
      org.respond_to?(:name_hide_allowed) && org.name_hide_allowed ? true : false
    end

    # ------------------------------------------------------------------ names for those outside
    def outward? = Thread.current[:gk_people_outward] == true && Thread.current[:gk_people_mailing] != true

    def with_request
      was = Thread.current[:gk_people_outward]
      Thread.current[:gk_people_outward] = true
      yield
    ensure
      Thread.current[:gk_people_outward] = was
    end

    def mailing
      was = Thread.current[:gk_people_mailing]
      Thread.current[:gk_people_mailing] = true
      yield
    ensure
      Thread.current[:gk_people_mailing] = was
    end

    # Should this account's name be hidden from the one reading now?
    def hide_name?(user)
      return false unless outward? && user.is_a?(::User) && user.type == 'User' && !::User.current.logged?

      hide_names_for_anonymous? || name_hidden_by_choice?(user)
    end

    # Title and organization, as the person has them; "a person" when neither is known
    def outward_label(user)
      p = person(user)
      [p&.title.presence, p&.organization&.name.presence].compact.join(', ').presence || ::I18n.t(:label_gk_people_name_hidden)
    end

    module UserPatch
      def name(*args)
        Outward.hide_name?(self) ? Outward.outward_label(self) : super
      end
    end

    # Every web request: names may be hidden while its page is drawn (only for one not signed in)
    module ControllerPatch
      def self.prepended(base)
        base.around_action :gk_people_outward
      end

      private

      def gk_people_outward(&block) = Outward.with_request(&block)
    end

    # A mail is never written with a hidden name, whoever triggered it
    module MailerPatch
      def mail(*args, &block)
        Outward.mailing { super }
      end
    end

    module PreferencePatch
      def self.prepended(base)
        base.safe_attributes 'gk_people_hide_folder_picture', 'gk_people_hide_name'
      end

      def gk_people_hide_folder_picture = (self[:gk_people_hide_folder_picture] || '0')
      def gk_people_hide_folder_picture=(v)
        self[:gk_people_hide_folder_picture] = v.to_s == '1' ? '1' : '0'
      end

      def gk_people_hide_name = (self[:gk_people_hide_name] || '0')
      def gk_people_hide_name=(v)
        self[:gk_people_hide_name] = v.to_s == '1' ? '1' : '0'
      end
    end
  end
end
