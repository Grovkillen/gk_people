# frozen_string_literal: true

require 'open3'
require 'tempfile'
require 'digest'
require 'base64'

module GkPeople
  # An account's own picture. Any account (a person's, a shared one, a group) may have one: six
  # small JPEGs made on the server with core's ImageMagick (Redmine::Thumbnail's convert), square, without metadata,
  # in gk_people_avatars; the picture given is never kept. The pictures leave only through GkPeopleAvatarsController,
  # to a signed-in user who may see people (GkPeople::Access.view?) and the account. The source own_picture is first
  # in core_stuff's register of picture sources (avatar_sources), or core's register where core has it; with the
  # function people.avatars off, or for one who may not see people, core's picture answers as before.
  module Avatars
    module_function

    FEATURE = 'people.avatars'
    SOURCE = 'gk_people_own_picture'
    POSITION = 10
    # The sizes core and the plugins ask for (14 to 64 px) and twice them for sharp screens
    SIZES = [16, 24, 32, 50, 64, 128].freeze
    MAX_BYTES = 10.megabytes
    QUALITY = '85'

    class Error < StandardError; end

    def on? = GkPeople.feature?(FEATURE)
    def convert_bin = defined?(::Redmine::Thumbnail::CONVERT_BIN) ? ::Redmine::Thumbnail::CONVERT_BIN : 'convert'

    # Makes the six sizes from the bytes of a picture and replaces the account's own. crop: { x:, y:, w:, h: } in the
    # picture's pixels (step 4); without it the middle square. Raises Error when the picture cannot be read.
    def store(principal, bytes, by: ::User.current, crop: nil)
      raise Error, 'empty' if bytes.blank?
      raise Error, 'too large' if bytes.bytesize > MAX_BYTES

      coder = coder_for(bytes) or raise Error, 'not a JPEG or PNG'
      made = Tempfile.create(['gk_people_avatar', '.img'], binmode: true) do |src|
        src.write(bytes)
        src.flush
        SIZES.to_h { |s| [s, convert(src.path, s, crop, coder: coder)] }
      end
      ::GkPeopleAvatar.transaction do
        ::GkPeopleAvatar.where(user_id: principal.id).delete_all
        made.each do |size, jpeg|
          ::GkPeopleAvatar.create!(user_id: principal.id, size: size, data: jpeg, checksum: Digest::SHA256.hexdigest(jpeg), set_by_id: by&.id)
        end
      end
      forget(principal.id)
      true
    end

    def remove(principal)
      n = ::GkPeopleAvatar.where(user_id: principal.id).delete_all
      forget(principal.id)
      n.positive?
    end

    def any?(principal) = checksums(principal.id).any?

    # One size as a square JPEG on white, read from the first frame, turned as the camera says, metadata stripped.
    # coder: the one reader ImageMagick may use (jpeg, png), so a file is never read as something else.
    def convert(path, size, crop, coder: nil)
      args = [convert_bin, "#{"#{coder}:" if coder}#{path}[0]", '-auto-orient']
      args += ['-crop', "#{crop[:w].to_i}x#{crop[:h].to_i}+#{crop[:x].to_i}+#{crop[:y].to_i}", '+repage'] if crop
      args += ['-background', 'white', '-alpha', 'remove', '-alpha', 'off', '-thumbnail', "#{size}x#{size}^",
               '-gravity', 'center', '-extent', "#{size}x#{size}", '-strip', '-quality', QUALITY, 'jpeg:-']
      out, err, status = Open3.capture3(*args, binmode: true)
      raise Error, err.to_s.strip.presence || 'convert failed' unless status.success? && out.b.start_with?("\xFF\xD8".b)

      out
    end

    # The reader for the bytes by their first bytes, never by a name: jpeg, png or nil
    def coder_for(bytes)
      b = bytes.to_s.b
      return 'jpeg' if b.start_with?("\xFF\xD8\xFF".b)
      return 'png' if b.start_with?("\x89PNG\r\n\x1A\n".b)

      nil
    end

    # Width and height as the picture is shown (turned as the camera says)
    def dimensions(path, coder: nil)
      out, err, status = Open3.capture3(convert_bin, "#{"#{coder}:" if coder}#{path}[0]", '-auto-orient', '-format', '%w %h', 'info:')
      raise Error, err.to_s.strip.presence || 'identify failed' unless status.success?

      out.split.map(&:to_i)
    end

    # A picture as a PNG data URL (from image_crop) to its bytes, at most 2 MB; nil for anything else
    def from_data_url(value)
      m = value.to_s.match(%r{\Adata:image/png;base64,([A-Za-z0-9+/=\s]+)\z})
      return nil unless m && m[1].bytesize <= 3.megabytes

      bytes = Base64.decode64(m[1])
      bytes.bytesize <= 2.megabytes ? bytes : nil
    end

    # Who may change an account's picture: an administrator; one with Manage pictures of persons, any account; their
    # own, everyone signed in while the setting own_avatar_for_all is on (on by default), else one with Change own
    # picture. Global permissions, no role has them from the start.
    # own_for_all: the setting, unless the caller says it (the scenarios check both without writing the setting, which
    # core caches for every thread of the process)
    def may_edit?(principal, viewer = ::User.current, own_for_all: own_for_all?)
      return false unless on? && viewer.logged? && principal.is_a?(::Principal) && !principal.is_a?(::AnonymousUser)
      return true if viewer.admin? || viewer.allowed_to?(:gk_people_manage_avatars, nil, global: true)
      return false unless principal.id == viewer.id

      own_for_all || viewer.allowed_to?(:gk_people_change_own_avatar, nil, global: true)
    end

    def own_for_all? = (::Setting.plugin_gk_people || {})['own_avatar_for_all'].to_s != '0'

    KINDS = %w[account_picture_set account_picture_removed account_picture_region_set account_icon_set].freeze

    # The event on the account (records), never with the picture: who did it is the event's user
    def event(principal, kind, details = {})
      GkPeople.write(principal, kind, details) if principal.is_a?(::User)
    end

    # size => checksum for the account, once per request
    def checksums(user_id)
      store = defined?(::RequestStore) ? (::RequestStore.store[:gk_people_avatars] ||= {}) : {}
      store[user_id] ||= ::GkPeopleAvatar.where(user_id: user_id).pluck(:size, :checksum).to_h
    end

    def forget(user_id)
      ::RequestStore.store[:gk_people_avatars]&.delete(user_id) if defined?(::RequestStore)
    end

    # The smallest stored size that fills the asked one, else the largest
    def pick(have, want) = have.keys.sort.find { |s| s >= want } || have.keys.max

    # May the viewer see this account's picture? Signed in, may see people, and may see the account
    # Signed in: may see people. Not signed in: only while the setting avatars_hide_anonymous is off (Outward). Then,
    # for an account, may see the account (core's rule for one not signed in).
    def visible?(principal, viewer = ::User.current)
      return false unless on?
      return false if viewer.logged? ? !Access.view?(viewer) : Outward.hide_pictures_for_anonymous?
      return true unless principal.is_a?(::User)

      Accounts.visible_account?(principal, viewer)
    end

    # The source: the img of the account's own picture, or nil for the next source
    # With the setting avatar_order folder_first the organization folder's picture comes first in this place (the
    # chosen icon stays after it), and the own picture only when the folder has none for the account
    def html(principal, options, view)
      return nil unless principal.is_a?(::Principal) && visible?(principal)

      if Outward.folder_first?
        folder = AvatarFolder.picture_html(principal, options, view)
        return folder if folder
      end
      have = checksums(principal.id)
      return nil if have.empty?

      want = (options[:size].presence || 50).to_i
      one = pick(have, want)
      two = pick(have, want * 2)
      url = ->(s) { view.gk_people_avatar_path(user_id: principal.id, size: s, v: have[s][0, 12]) }
      css = (['avatar', 'gravatar', 'gk-people-avatar'] + options[:class].to_s.split).uniq.join(' ')
      attrs = { alt: '', title: options[:title].presence || principal.name, class: css, width: want, height: want }
      attrs[:srcset] = "#{url.(two)} 2x" if two != one
      view.image_tag(url.(one), attrs)
    end

    # In core's register where core has one (the upstream form of core_stuff's), else core_stuff's
    def register!
      reg = if defined?(::Redmine::AvatarSources) then ::Redmine::AvatarSources
            elsif defined?(::GkCoreStuff::AvatarSources) then ::GkCoreStuff::AvatarSources
            end
      reg&.register(SOURCE, position: POSITION) { |principal, options, view| html(principal, options, view) }
    end
  end
end
