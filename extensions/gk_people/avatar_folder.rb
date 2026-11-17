# frozen_string_literal: true

require 'digest'

module GkPeople
  # The picture folder per organization. An administrator gives an organization a folder on the
  # server or the network and a rule for the file names (the login, the e-mail address, or an identifier of a
  # scheme such as the employee number); off by default. An account's person, at the organization or under one with
  # a folder on (the nearest above), gets the picture <name>.jpg, .jpeg or .png from it, at most 10 MB. The pictures
  # are made with ImageMagick one size at a time when they are first asked for, and made again when the file's stamp
  # (modified time and length) changes; the file is never copied. A folder that cannot be reached, or a file that
  # is not there, gives the next source (Gravatar, the initials). The source is after an own picture and a chosen
  # icon. The pictures of files that are gone, or of a folder switched off, are removed by ops' daily job and when
  # the organization is saved.
  module AvatarFolder
    module_function

    SOURCE = 'gk_people_folder_picture'
    POSITION = 30
    EXTENSIONS = { 'jpg' => 'jpeg', 'jpeg' => 'jpeg', 'png' => 'png' }.freeze
    RULES = %w[login email].freeze
    # A name taken into a path: letters, digits and . _ @ + - only, never a folder of its own
    SAFE_NAME = /\A[\p{L}\p{N}._@+-]{1,120}\z/
    TTL = 60 # seconds a folder's reachability and a lookup are remembered in the process
    JOB_KEY = 'gk_people.avatar_sweep'

    Found = Struct.new(:path, :name, :coder, :stamp, :region)

    @mutex = Mutex.new
    @memo = {}

    # The rule of an organization as it is stored: login, email or scheme:<key>; never a scheme of tokens (a secret
    # is never a file name)
    def rules = RULES + name_schemes.map { |s| "scheme:#{s.key}" }
    def name_schemes = ::GkPeopleScheme.where(active: true).order(:position, :name).reject(&:token?)

    def valid_rule?(rule)
      r = rule.to_s
      return true if RULES.include?(r)

      s = r.start_with?('scheme:') && ::GkPeopleScheme.find_by(key: r.delete_prefix('scheme:'))
      s.present? && !s.token?
    end

    # The organization whose folder the person uses: her own or the nearest above with the folder on
    def organization_for(person)
      org = person&.organization
      20.times do
        return nil unless org
        return org if org.avatar_folder_on && org.avatar_folder.present?

        org = org.parent
      end
      nil
    end

    def person_for(principal) = principal.is_a?(::User) ? ::GkPeoplePerson.where(user_id: principal.id, active: true).order(:id).first : nil

    # The name the rule gives the account, or nil when it gives none or one that is not safe in a path
    def name_for(user, person, rule)
      v = case rule.to_s
          when 'login' then user.login
          when 'email' then user.mail
          when /\Ascheme:(.+)\z/
            key = Regexp.last_match(1)
            person.identifiers_in_force.find { |i| i.scheme.key == key && !i.scheme.token? }&.value
          end
      v = v.to_s.strip
      v.match?(SAFE_NAME) && !v.include?('..') ? v : nil
    end

    # The file as it is shown: nil when the person hides the organization's picture and the organization allows it
    def shown_file_for(principal)
      person = person_for(principal)
      return nil if Outward.folder_picture_hidden?(principal, organization_for(person))

      file_for(principal)
    end

    # The account's file in the folder, or nil (no folder, no name, not reachable, not there, too large)
    def file_for(principal)
      person = person_for(principal)
      org = organization_for(person)
      return nil unless org

      name = name_for(principal, person, org.avatar_name_rule)
      return nil unless name

      found = remember("file:#{org.id}:#{principal.id}:#{name}") { find(org.avatar_folder, name) }
      return nil unless found

      # The chosen part (step 4) is part of the stamp, so a new part makes the pictures again
      region = ::GkPeopleAvatarRegion.find_by(user_id: principal.id)
      region ? Found.new(found.path, found.name, found.coder, "#{found.stamp}-#{Digest::SHA256.hexdigest(region.signature)[0, 8]}", region) : found
    end

    def find(folder, name)
      return nil unless reachable?(folder)

      EXTENSIONS.each do |ext, coder|
        path = ::File.join(folder, "#{name}.#{ext}")
        next unless ::File.file?(path)

        st = ::File.stat(path)
        return nil if st.size > Avatars::MAX_BYTES || st.size.zero?

        return Found.new(path, ::File.basename(path), coder, "#{st.mtime.to_i}-#{st.size}")
      end
      nil
    rescue SystemCallError
      nil
    end

    def reachable?(folder) = remember("dir:#{folder}") { ::File.directory?(folder) }

    # A value kept TTL seconds in the process (a folder on the network is asked once a minute, not per picture)
    def remember(key)
      now = Time.now.to_i
      hit = @mutex.synchronize { @memo[key] }
      return hit[1] if hit && now - hit[0] < TTL

      v = yield
      @mutex.synchronize do
        @memo.clear if @memo.size > 5000
        @memo[key] = [now, v]
      end
      v
    end

    def forget! = @mutex.synchronize { @memo.clear }

    # The chosen part in the file's pixels, or nil for the middle square; the picture's size is read with ImageMagick
    def crop_for(file)
      r = file.region
      return nil unless r

      w, h = Avatars.dimensions(file.path, coder: file.coder)
      side = (r.s.to_f * [w, h].min).round
      { x: (r.x.to_f * w).round, y: (r.y.to_f * h).round, w: side, h: side }
    end

    # The picture of one size for the file, made now unless made from the same stamp before
    def picture(principal, file, size)
      row = ::GkPeopleAvatarFile.find_by(user_id: principal.id, size: size)
      return row if row && row.file_stamp == file.stamp && row.file_name == file.name

      jpeg = Avatars.convert(file.path, size, crop_for(file), coder: file.coder)
      row ||= ::GkPeopleAvatarFile.new(user_id: principal.id, size: size)
      row.update!(data: jpeg, checksum: Digest::SHA256.hexdigest(jpeg), file_name: file.name, file_stamp: file.stamp)
      row
    end

    # The source: the img of the folder's picture, or nil for the next source
    # The source in its place: nothing here when the folder comes first (the own picture's place shows it)
    def html(principal, options, view) = Outward.folder_first? ? nil : picture_html(principal, options, view)

    # The folder's picture for the account, or nil: not visible, no file, or hidden by the person where the
    # organization allows it (Outward)
    def picture_html(principal, options, view)
      return nil unless principal.is_a?(::User) && Avatars.visible?(principal)

      file = shown_file_for(principal)
      return nil unless file

      want = (options[:size].presence || 50).to_i
      one = Avatars::SIZES.find { |s| s >= want } || Avatars::SIZES.last
      two = Avatars::SIZES.find { |s| s >= want * 2 } || Avatars::SIZES.last
      v = Digest::SHA256.hexdigest("#{file.name}:#{file.stamp}")[0, 12]
      url = ->(s) { view.gk_people_avatar_folder_path(user_id: principal.id, size: s, v: v) }
      css = (['avatar', 'gravatar', 'gk-people-avatar', 'gk-people-avatar-folder'] + options[:class].to_s.split).uniq.join(' ')
      attrs = { alt: '', title: options[:title].presence || principal.name, class: css, width: want, height: want }
      attrs[:srcset] = "#{url.(two)} 2x" if two != one
      view.image_tag(url.(one), attrs)
    end

    # The pictures whose file is gone, whose name rule no longer leads to it, or whose folder is off. Returns the
    # number of accounts whose pictures were removed.
    def sweep!
      forget!
      gone = ::GkPeopleAvatarFile.distinct.pluck(:user_id).select do |uid|
        u = ::Principal.find_by(id: uid)
        f = u && file_for(u)
        f.nil? || ::GkPeopleAvatarFile.where(user_id: uid).where.not(file_name: f.name).exists?
      end
      ::GkPeopleAvatarFile.where(user_id: gone).delete_all if gone.any?
      gone.size
    end

    def scheduled!(ops_run)
      n = sweep!
      ops_run.step(::I18n.t(:text_gk_people_avatar_sweep_done, count: n))
    end

    def register!
      reg = if defined?(::Redmine::AvatarSources) then ::Redmine::AvatarSources
            elsif defined?(::GkCoreStuff::AvatarSources) then ::GkCoreStuff::AvatarSources
            end
      reg&.register(SOURCE, position: POSITION) { |principal, options, view| html(principal, options, view) }
      return unless defined?(::GkOps::Scheduler) && !::GkOps::Scheduler.registry.key?(JOB_KEY)

      # the one-line description where ops takes one
      more = ::GkOps::Scheduler.method(:register).parameters.any? { |_t, n| n == :description } ? { description: :text_gk_people_avatar_sweep_job } : {}
      ::GkOps::Scheduler.register(JOB_KEY, name: :label_gk_people_avatar_sweep, plugin: :gk_people, at: '00:20', **more) { |run| scheduled!(run) }
    end
  end
end
