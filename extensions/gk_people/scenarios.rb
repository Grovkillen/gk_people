# frozen_string_literal: true

require 'tmpdir'

module GkPeople
  # gk_scenarios loads this file and calls register_scenarios! once every plugin is in; project_types and tags find
  # the scenario's organizations and persons through people
  def self.register_scenarios! = Scenarios.register_scenarios!
  # (closed without GK GUI Stuff, like every page of people's, gate.rb)
  def self.scenario_org(ctx, key) = GkPeople.gui? ? Scenarios.scenario_org(ctx, key) : nil
  def self.scenario_person(ctx, key) = GkPeople.gui? ? Scenarios.scenario_person(ctx, key) : nil

  module Scenarios
    # people's own steps and expectations in scenarios (gk_scenarios calls this):
    # * people (order 150, before the issues): who may do what with the registers (permissions given to the
    #   scenario's roles), the identifier schemes, the organizations and the persons with their identifiers. A person
    #   with user: is the scenario person's account, found or given its person; the others are made by the person the
    #   scenario names. Everything is found again by its natural key (scheme key, organization name, account, name).
    # * people_sync (order 160): what an external system sends (people.sync: the posts as the source would send them,
    #   the source's own names and ids, not words of the scenario), run through the same upsert as the REST endpoint,
    #   as the person named (her role has sync); each call twice, so that the second shows that nothing changes.
    # * group_texts (order 300): a group's texts (What the group does, Authority) written as the person named.
    # * people_shared (order 170) and people_shared_records (order 480): actor_records, a shared computer: the Redmine
    #   group the setting names (set when empty), its accounts (no person of their own), their memberships (the
    #   ceiling) and their matrix; after the issues, notes written on a shared account with the person at the computer.
    PERMS = { 'view' => :gk_people_view, 'manage' => :gk_people_manage, 'manage_identifiers' => :gk_people_manage_identifiers, 'sync' => :gk_people_sync,
              'responsibilities' => :gk_people_manage_responsibilities, 'credentials' => :gk_people_manage_credentials }.freeze

    def self.register_scenarios!
      return unless defined?(::GkScenarios::Steps)

      ::GkScenarios::Steps.register('people', plugin: :gk_people, order: 150) do |ctx|
        s = ctx.scenario
        data = s.data['people'] || {}
        # Settings the scenario needs that are off in a new installation (people: { settings: {... } })
        if data['settings'].is_a?(Hash) && data['settings'].any?
          now = ::Setting.plugin_gk_people.is_a?(Hash) ? ::Setting.plugin_gk_people.dup : {}
          diff = data['settings'].to_h { |k, v| [k.to_s, v.to_s] }.reject { |k, v| now[k].to_s == v }
          ::Setting.plugin_gk_people = now.merge(diff) if diff.any?
          ctx.note(:people_settings, 'settings', nil, diff.any?)
        end
        Array(data['permissions']).each do |row|
          role = ctx.get(:role, row['role'])
          missing = Array(row['may']).map { |m| PERMS.fetch(m.to_s) } - role.permissions
          missing.each { |perm| role.add_permission!(perm) }
          ctx.note(:people_permission, row['role'], role, missing.any?)
        end
        # every account of the scenario has its person: made by itself when the account is new (create_person_on_user),
        # filled in here for accounts made before people was there
        s.list(:users).each do |u|
          user = ctx.get(:user, u['key'])
          made = GkPeople.person_for(user).nil?
          ctx.note(:account_person, u['key'], Accounts.ensure_person!(user, how: 'scenario', force: true), made)
        end
        Array(data['schemes']).each do |sc|
          scheme = ::GkPeopleScheme.find_by(key: sc['key'])
          created = scheme.nil?
          unless scheme
            scheme = ::GkPeopleScheme.new(name: s.t(:people, :schemes, sc['key']), unique_value: sc['unique'] == true,
                                        format: sc['format'], link_template: sc['link'], icon: sc['icon'],
                                        position: (::GkPeopleScheme.maximum(:position) || 0) + 1)
            scheme.key = sc['key']
            scheme.kind = sc['kind'] || 'contact'
            scheme.show_on_list = sc['show_on']
            scheme.save!
          end
          ctx.note(:scheme, sc['key'], scheme, created)
        end
        # kinds of organization of the scenario's own
        Array(data['org_kinds']).each do |key|
          kind = ::GkPeopleOrgKind.find_by(key: key)
          created = kind.nil?
          kind ||= ::GkPeopleOrgKind.create!(key: key, name: s.t(:people, :org_kinds, key), position: (::GkPeopleOrgKind.maximum(:position) || 0) + 1)
          ctx.note(:org_kind, key, kind, created)
        end
        Array(data['organizations']).each do |o|
          name = s.t(:people, :organizations, o['key'], :name)
          org = ::GkPeopleOrganization.find_by(name: name)
          created = org.nil?
          unless org
            by = o['by'] ? ctx.get(:user, o['by']) : nil
            org = ::GkPeopleOrganization.new(name: name, org_no: o['org_no'], country: o['country'],
                                           risk_class: o['risk_class'], approval_valid_to: (o['valid_to'] ? ctx.day(o['valid_to']) : nil),
                                           created_by_id: by&.id)
            org.kind_keys = Array(o['kinds'] || o['kind'] || 'customer')
            org.approval_status = o['approval'] if o['approval']
            org.short_name = o['short_name'] if o['short_name']
            place!(ctx, org, o)
            by ? ctx.as(by) { org.save! } : org.save!
          end
          # The place the scenario gives and an organization made before does not have yet (only empty fields; what
          # is there is never overwritten), saved as the person named
          unless created
            place!(ctx, org, o)
            if org.changed?
              by = o['by'] ? ctx.get(:user, o['by']) : nil
              by ? ctx.as(by) { org.save! } : org.save!
            end
          end
          # the instance's owner: owner: '*' for every language, or the languages it answers for
          Owner.mark!(org, o['owner'].to_s) if o['owner'] && org.owner_langs.to_s != o['owner'].to_s
          ctx.note(:organization, o['key'], org, created)
        end
        Array(data['persons']).each do |pr|
          by = ctx.get(:user, pr['by'] || pr['user'])
          org = pr['organization'] ? ctx.get(:organization, pr['organization']) : nil
          texts = s.t?(:people, :persons, pr['key']) || {}
          person = nil
          created = false
          ctx.as(by) do
            if pr['user']
              user = ctx.get(:user, pr['user'])
              before = GkPeople.person_for(user)
              person = before || Accounts.ensure_person!(user, how: 'scenario', force: true)
              created = before.nil?
            else
              first = s.t(:people, :persons, pr['key'], :first_name)
              last = s.t(:people, :persons, pr['key'], :last_name)
              person = ::GkPeoplePerson.find_by(first_name: first, last_name: last, user_id: nil)
              created = person.nil?
              person ||= ::GkPeoplePerson.create!(first_name: first, last_name: last, kind: pr['kind'] || 'external', created_by_id: by.id)
            end
            # what the scenario says and the person does not have yet; nothing already there is overwritten
            person.organization_id ||= org&.id
            person.title ||= texts['title'].presence
            person.email ||= pr['email']
            person.phone ||= pr['phone']
            person.save! if person.changed?
            Array(pr['identifiers']).each do |idf|
              scheme = ctx.get(:scheme, idf['scheme'])
              next if Identify.lookup(scheme.key, idf['value'].to_s)&.id == person.id

              ident = person.identifiers.build(scheme: scheme, preferred: idf['preferred'] == true, created_by_id: by.id)
              ident.raw_value = idf['value'].to_s
              ident.save!
            end
          end
          ctx.note(:person, pr['key'], person, created)
        end
        # groups of people: made by the person named, members added by her; found again by name
        Array(data['groups']).each do |gr|
          by = ctx.get(:user, gr['by'])
          texts = s.t?(:people, :groups, gr['key']) || {}
          group = ::GkPeopleGroup.active.find_by('lower(name) = ?', texts['name'].to_s.downcase)
          created = group.nil?
          ctx.as(by) do
            group ||= ::GkPeopleGroup.create!(name: texts['name'], description: texts['description'], created_by_id: by.id)
            Array(gr['members']).each { |k| PersonGroups.add(group, ctx.get(:person, k), by: by) }
          end
          ctx.note(:person_group, gr['key'], group, created)
        end
        # the record of processing: texts the organization writes over the declaration, per table (only empty fields)
        Array(data['processing']).each do |pp|
          row = ::GkPeopleProcessing.find_or_initialize_by(table_name: pp['table'])
          created = row.new_record?
          texts = s.t?(:people, :processing, pp['table']) || {}
          %w[purpose retention visible_to].each { |a| row[a] = texts[a] if row[a].blank? && texts[a].present? }
          row.legal_basis ||= pp['basis']
          row.save! if row.changed?
          ctx.note(:processing, pp['table'], row, created)
        end
      end

      # ppl_times_instant: synchronisation, grants and lock times keep their instants with their zone (migration 029).
      # The scenario's first sync log, role grant, credential and assignment, each with a copy, and two elevations with
      # an action each, are put into the hour that comes twice the night summer time ends (00:30Z and 01:30Z on
      # 25 October 2026, both 02:30 Swedish time), the lower id to the later one, and read back as the instants they
      # were and in that order; a person's PIN lock reads back as it was; an elevation that ends in an hour is open and
      # one that ended a minute ago is not. Rolled back.
      ::GkScenarios::Expect.register('ppl_times_instant') do |_ctx, _e|
        failed = []
        first = ::Time.utc(2026, 10, 25, 0, 30)
        second = ::Time.utc(2026, 10, 25, 1, 30)
        pairs = [[::GkPeopleSyncLog, %i[started_at finished_at]], [::GkPeopleRoleGrant, %i[granted_at revoked_at]],
                 [::GkPeopleCredential, %i[revoked_at]], [::GkPeopleAssignment, %i[ended_at]]]
        check = lambda do |model, cols, later, earlier|
          rows = model.where(id: [later.id, earlier.id]).order(cols.first, :id).to_a
          failed << "#{model.name} order" unless rows.map(&:id) == [earlier.id, later.id]
          cols.each do |c|
            got = rows.map { |r| r.public_send(c)&.getutc }
            failed << "#{model.name}.#{c} (#{got.map { |t| t&.iso8601 }.join(' ')})" unless got == [first, second]
          end
        end
        ::ActiveRecord::Base.transaction do
          pairs.each do |model, cols|
            base = model.order(:id).first
            (failed << "#{model.name}: none") && next unless base

            copy = base.dup
            copy.save!(validate: false)
            base.update_columns(cols.index_with { second })
            copy.update_columns(cols.index_with { first })
            check.call(model, cols, base, copy)
          end
          user_id = ::User.current.id
          make = ->(at) { ::GkPeopleElevation.new(user_id: user_id, started_at: at, expires_at: at + 3600, last_activity_at: at, ended_at: at + 600).tap { |x| x.save!(validate: false) } }
          later = make.call(second)
          earlier = make.call(first)
          check.call(::GkPeopleElevation, %i[started_at last_activity_at], later, earlier)
          act = ->(el, at) { ::GkPeopleElevationAction.new(elevation_id: el.id, controller: 'scenario', action: 'instant', at: at).tap { |x| x.save!(validate: false) } }
          check.call(::GkPeopleElevationAction, %i[at], act.call(later, second), act.call(earlier, first))
          open = ::GkPeopleElevation.new(user_id: user_id, started_at: ::Time.current, expires_at: ::Time.current + 3600).tap { |x| x.save!(validate: false) }
          gone = ::GkPeopleElevation.new(user_id: user_id, started_at: ::Time.current - 3600, expires_at: ::Time.current - 60).tap { |x| x.save!(validate: false) }
          ids = ::GkPeopleElevation.open.where(id: [open.id, gone.id]).pluck(:id)
          failed << "elevation open (#{ids.inspect})" unless ids == [open.id]
          person = ::GkPeoplePerson.order(:id).first
          if person
            person.update_columns(pin_locked_until: first)
            failed << 'pin_locked_until' unless ::GkPeoplePerson.find(person.id).pin_locked_until&.getutc == first
          else
            failed << 'GkPeoplePerson: none'
          end
          raise ::ActiveRecord::Rollback
        end
        { 'ok' => failed.empty?, 'want' => 'the instants in the doubled hour, in order; open elevations by the instant', 'got' => failed.empty? ? 'the instants in the doubled hour, in order; open elevations by the instant' : "not: #{failed.join(', ')}" }
      end

      # ppl_actor_instant: the actor records' captured_at keeps the instant with its zone (migration 028). The
      # scenario's first record and a copy of it are moved into the hour that comes twice the night summer time ends
      # (00:30Z and 01:30Z on 25 October 2026, both 02:30 Swedish time), the lower id to the later one, and read back as
      # the instants they were and in that order (sorted). Rolled back.
      ::GkScenarios::Expect.register('ppl_actor_instant') do |_ctx, _e|
        failed = []
        first = ::Time.utc(2026, 10, 25, 0, 30)
        second = ::Time.utc(2026, 10, 25, 1, 30)
        base = ::GkPeopleActorRecord.order(:id).first
        next({ 'ok' => false, 'want' => 'an actor record', 'got' => 'none' }) unless base

        ::ActiveRecord::Base.transaction do
          copy = base.dup
          copy.save!(validate: false)
          pair = [base, copy]
          pair[0].update_columns(captured_at: second)
          pair[1].update_columns(captured_at: first)
          rows = ::GkPeopleActorRecord.where(id: pair.map(&:id)).sorted.to_a.reverse
          failed << 'order' unless rows.map(&:id) == [pair[1].id, pair[0].id]
          failed << "read_back (#{rows.map { |r| r.captured_at.getutc.iso8601 }.join(' ')})" unless rows.map { |r| r.captured_at.getutc } == [first, second]
          raise ::ActiveRecord::Rollback
        end
        { 'ok' => failed.empty?, 'want' => 'two instants in the doubled hour, in order', 'got' => failed.empty? ? 'two instants in the doubled hour, in order' : "not: #{failed.join(', ')}" }
      end

      # ppl_avatar_own: <user key>, outsider: <user key>. The account's own picture: a picture made
      # here is stored as the six square JPEGs, each its size, nothing else kept; an administrator (who may see people)
      # gets it from core's avatar, the size asked and twice it for sharp screens, through people's address; the outsider
      # (signed in, may not see people), an anonymous user and the function people.avatars off get core's picture; the
      # address answers the picture only to one who may see it. Rolled back.
      ::GkScenarios::Expect.register('ppl_avatar_own') do |ctx, e|
        av = ::GkPeople::Avatars
        u = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['ppl_avatar_own'].to_s))
        outsider = e['outsider'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['outsider'].to_s))
        admin = ::User.active.where(admin: true).order(:id).first
        next({ 'ok' => false, 'want' => 'a user, an outsider and an administrator', 'got' => [u, outsider, admin].map { |x| x&.login || '-' }.join(', ') }) unless u && outsider && admin

        mark = 'gk-people-avatar'
        show = ->(who, size) { ctx.as(who) { ::IssuesController.renderer.render(inline: '<%= avatar(u, size: s) %>', locals: { u: u, s: size }) } }
        # What the address answers (GkPeopleAvatarsController#show): the size, to one who may see it
        serve = ->(who, size) { av.visible?(u, who) ? ::GkPeopleAvatar.find_by(user_id: u.id, size: size)&.data : nil }
        failed = []
        begin
          ::ActiveRecord::Base.transaction do
            scenario_feature!(av::FEATURE) # off for a new installation; rolled back with the rest
            png, _err, st = ::Open3.capture3(av.convert_bin, '-size', '300x200', 'gradient:#3366cc-#ffcc00', 'png:-', binmode: true)
            (failed << 'no picture made') && raise(::ActiveRecord::Rollback) unless st.success?

            av.store(u, png, by: admin)
            rows = ::GkPeopleAvatar.where(user_id: u.id).order(:size).to_a
            failed << "sizes #{rows.map(&:size).inspect}" unless rows.map(&:size) == av::SIZES
            rows.each do |r|
              dim, = ::Open3.capture3(av.convert_bin, 'jpeg:-', '-format', '%wx%h %m', 'info:', stdin_data: r.data, binmode: true)
              failed << "#{r.size}: #{dim.strip}" unless dim.strip == "#{r.size}x#{r.size} JPEG"
            end
            failed << 'the picture given is kept' if rows.any? { |r| r.data == png }
            html = show.(admin, 24)
            failed << 'admin: not the own picture' unless html.include?(mark) && html.include?("/gk_people/avatars/#{u.id}/24?") && html.include?("/gk_people/avatars/#{u.id}/50?v=")
            failed << 'admin: no picture from the address' unless serve.(admin, 24)&.b&.start_with?("\xFF\xD8".b)
            failed << 'outsider: the own picture' if show.(outsider, 24).include?(mark)
            failed << 'outsider: a picture from the address' if serve.(outsider, 24)
            failed << 'anonymous: the own picture' if show.(::User.anonymous, 24).include?(mark)
            if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
              ::GkRecords::Features.set!(av::FEATURE, false, user: admin)
              failed << 'function off: the own picture' if show.(admin, 24).include?(mark)
            end
            av.remove(u)
            failed << 'removed: the own picture' if show.(admin, 24).include?(mark)
            raise ::ActiveRecord::Rollback
          end
        ensure
          ::GkRecords::Features.forget! if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
          av.forget(u.id)
        end
        want = 'six square JPEGs; admin gets them; outsider, anonymous and off get core'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # ppl_avatar_folder: <user key>, outsider: <user key>. The organization's picture folder: a
      # folder made here with <login>.png, switched on for the user's organization. An administrator gets the folder's
      # picture through people's address, made as a square JPEG once and again only when the file changes; an own
      # picture goes before it; the outsider, a folder that cannot be reached and the folder off give core's picture; a
      # name with a path in it is never used; the pictures of a file that is gone are swept. Rolled back.
      ::GkScenarios::Expect.register('ppl_avatar_folder') do |ctx, e|
        av = ::GkPeople::Avatars
        af = ::GkPeople::AvatarFolder
        u = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['ppl_avatar_folder'].to_s))
        outsider = e['outsider'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['outsider'].to_s))
        admin = ::User.active.where(admin: true).order(:id).first
        org = u && ::GkPeoplePerson.where(user_id: u.id).first&.organization
        next({ 'ok' => false, 'want' => 'a user with an organization, an outsider and an administrator', 'got' => [u&.login, org&.name, outsider&.login, admin&.login].map { |x| x || '-' }.join(', ') }) unless u && org && outsider && admin

        show = ->(who) { ctx.as(who) { ::IssuesController.renderer.render(inline: '<%= avatar(u, size: 24) %>', locals: { u: u }) } }
        make = lambda do |path, color|
          _o, err, st = ::Open3.capture3(av.convert_bin, '-size', '120x90', "xc:#{color}", "png:#{path}")
          raise "picture not made: #{err}" unless st.success?
        end
        dimension = ->(data) { ::Open3.capture3(av.convert_bin, 'jpeg:-', '-format', '%wx%h', 'info:', stdin_data: data, binmode: true).first.strip }
        failed = []
        dir = ::Dir.mktmpdir('gk_people_avatar_folder')
        begin
          ::ActiveRecord::Base.transaction do
            scenario_feature!(av::FEATURE) # off for a new installation; rolled back with the rest
            path = ::File.join(dir, "#{u.login}.png")
            make.(path, '#2a7f62')
            org.update_columns(avatar_folder_on: true, avatar_folder: dir, avatar_name_rule: 'login')
            af.forget!
            html = show.(admin)
            failed << 'admin: not the folder picture' unless html.include?('gk-people-avatar-folder') && html.include?("/gk_people/avatars/#{u.id}/folder/24?v=")
            file = af.file_for(u)
            first = file && af.picture(u, file, 24)
            failed << "made: #{first ? dimension.(first.data) : 'none'}" unless first && dimension.(first.data) == '24x24'
            again = file && af.picture(u, file, 24)
            failed << 'made again from the same file' unless again && first && again.checksum == first.checksum && again.updated_at == first.updated_at
            make.(path, '#c0392b')
            ::File.utime(::Time.now + 60, ::Time.now + 60, path)
            af.forget!
            changed = af.file_for(u)
            remade = changed && af.picture(u, changed, 24)
            failed << 'not made again when the file changed' unless remade && first && remade.checksum != first.checksum
            failed << 'outsider: the folder picture' if show.(outsider).include?('gk-people-avatar')
            png, = ::Open3.capture3(av.convert_bin, '-size', '60x60', 'xc:#3366cc', 'png:-', binmode: true)
            av.store(u, png, by: admin)
            html = show.(admin)
            failed << 'own picture not first' unless html.include?('gk-people-avatar') && !html.include?('gk-people-avatar-folder')
            av.remove(u)
            org.update_columns(avatar_folder: ::File.join(dir, 'not-there'))
            af.forget!
            failed << 'unreachable folder: a picture' if show.(admin).include?('gk-people-avatar')
            org.update_columns(avatar_folder: dir, avatar_folder_on: false)
            af.forget!
            failed << 'folder off: a picture' if show.(admin).include?('gk-people-avatar')
            probe = ::Struct.new(:login, :mail).new('..\\secrets', 'a/b@c')
            failed << 'a path taken as a name' if af.name_for(probe, nil, 'login') || af.name_for(probe, nil, 'email')
            org.update_columns(avatar_folder_on: true)
            ::File.delete(path)
            af.sweep!
            failed << 'pictures of a file that is gone kept' if ::GkPeopleAvatarFile.where(user_id: u.id).exists?
            raise ::ActiveRecord::Rollback
          end
        ensure
          ::FileUtils.rm_rf(dir)
          af.forget!
          av.forget(u.id)
          ::GkRecords::Features.forget! if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
        end
        want = 'the folder picture made once and again on change; own first; outsider, unreachable and off get core; swept'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # people.avatars: invented pictures and icons on the scenario's accounts, so that every series
      # shows them. { user: <user key> | shared: <people.shared account key> | group: <group key>, picture: <colour> |
      # icon: <name> }. A picture is a silhouette drawn with ImageMagick (head and shoulders on the colour), made into
      # the six sizes as any picture is; an account that already has one keeps it.
      ::GkScenarios::Steps.register('people_avatars', plugin: :gk_people, order: 370) do |ctx|
        rows = Array((ctx.scenario.data['people'] || {})['avatars'])
        next if rows.empty?

        scenario_feature!(Avatars::FEATURE)

        by = ::User.active.where(admin: true).order(:id).first
        rows.each do |a|
          who, key = avatar_target(ctx, a)
          if a['picture']
            next ctx.note(:people_avatar, key, who, false) if Avatars.any?(who)

            colour = a['picture'].to_s
            raise ::GkScenarios::Error, "people avatars #{key}: picture is a colour, #rrggbb" unless colour.match?(/\A#\h{6}\z/)

            png, err, st = ::Open3.capture3(Avatars.convert_bin, '-size', '400x400', "radial-gradient:#{colour}-#ffffff",
                                            '-fill', '#f8f9fa', '-draw', 'circle 200 165 200 240', '-draw', 'ellipse 200 420 150 130 180 360',
                                            'png:-', binmode: true)
            raise ::GkScenarios::Error, "people avatars #{key}: #{err}" unless st.success?

            Avatars.store(who, png, by: by)
            ctx.note(:people_avatar, key, who, true)
          else
            next ctx.note(:people_avatar, key, who, false) if AvatarIcon.icon_for(who) == a['icon'].to_s

            raise ::GkScenarios::Error, "people avatars #{key}: unknown icon #{a['icon']}" unless AvatarIcon.set(who, a['icon'].to_s, by: by)

            ctx.note(:people_avatar, key, who, true)
          end
        end
      end

      # ppl_avatar_seeded: <people.avatars row as user/shared/group key>, kind: picture | icon. What the step people_avatars
      # gave the account is what core's avatar shows an administrator: the own picture through people's address, or the
      # icon in its field.
      ::GkScenarios::Expect.register('ppl_avatar_seeded') do |ctx, e|
        a = e.slice('user', 'shared', 'group')
        who, key = avatar_target(ctx, a)
        admin = ::User.active.where(admin: true).order(:id).first
        html = ctx.as(admin) { ::IssuesController.renderer.render(inline: '<%= avatar(u, size: 50) %>', locals: { u: who }) }
        got = if html.include?('gk-people-avatar-icon') then 'icon'
              elsif html.include?("/gk_people/avatars/#{who.id}/50?") then 'picture'
              else 'core'
              end
        { 'ok' => got == e['kind'].to_s, 'want' => "#{key}: #{e['kind']}", 'got' => "#{key}: #{got}" }
      end

      # ppl_sql_portable: <person key>. The searches find what they found before, without SQL of
      # PostgreSQL's own: a person by first and last name together, an organization by its number written with a dash,
      # and the organization's digits column kept by the model. The SQL built has no concat_ws, NULLS, regexp_replace or
      # CAST. Nämnd i finds the person in a list of a record's event and not when only a longer number holds her id
      # (12 is never 112). Rolled back.
      ::GkScenarios::Expect.register('ppl_sql_portable') do |ctx, e|
        p = scenario_person(ctx, e['ppl_sql_portable'])
        org = ::GkPeopleOrganization.where.not(org_no: [nil, '']).order(:id).first
        next({ 'ok' => false, 'want' => 'a person and an organization with a number', 'got' => [p&.id, org&.id].inspect }) unless p && org

        failed = []
        full = [p.first_name, p.last_name].compact.join(' ')
        failed << "person by #{full}" unless full.present? && ::GkPeoplePerson.search(full).exists?(p.id)
        digits = org.org_no.gsub(/\D/, '')
        failed << "digits column #{org.org_no_digits.inspect}" unless org.org_no_digits == digits
        dashed = digits.size > 6 ? "#{digits[0, 6]}-#{digits[6..]}" : digits
        failed << "organization by #{dashed}" unless ::GkPeopleOrganization.by_number(dashed).exists?(org.id)
        failed << "organization by name" unless ::GkPeopleOrganization.search(org.name.to_s[0, 4]).exists?(org.id)
        sqls = [::GkPeoplePerson.search(full), ::GkPeopleOrganization.search('x'), ::GkPeopleGroup.search('x'),
                ::GkPeopleCredential.sorted, ::GkPeopleAssignment.sorted, ::GkPeopleOrganization.by_number('556')].map(&:to_sql)
        bad = sqls.grep(/concat_ws|NULLS (FIRST|LAST)|regexp_replace|CAST\(/i)
        failed << "SQL #{bad.first[0, 80]}" if bad.any?
        if defined?(::GkRecordsEvent)
          entry = ::GkPeople::Processing.entries(::GkPeople::Processing.tables).detect { |x| x.table == ::GkPeople::SubjectAccess::EVENTS_TABLE }
          count = -> { ::GkPeople::SubjectAccess.mentioned(::ActiveRecord::Base.connection, entry, p, nil)&.count.to_i }
          ::ActiveRecord::Base.transaction do
            before = count.()
            ev = ->(ids) { ::GkRecordsEvent.new(target_type: 'issue', target_id: 0, kind: 'gk_people_sql_check', origin: 'system', details: { 'who' => { 'refs' => 'person', 'ids' => ids } }.to_json).tap { |x| x.save!(validate: false) } }
            ev.([7, p.id])
            ev.(["#{p.id}1".to_i])
            after = count.()
            failed << "Nämnd i #{before} -> #{after}, not one more" unless after == before + 1
            raise ::ActiveRecord::Rollback
          end
        end
        want = 'searches without SQL of PostgreSQL\'s own; Nämnd i exact in lists'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # ppl_outward: <user key>. What those outside see. Order: with the own picture first an
      # administrator gets the own picture; with the organization's first the folder's, and the own one again when the
      # folder has none. Hiding: a person's choice hides the folder's picture only where the organization allows it.
      # Not signed in: no picture while pictures are hidden; with that off, what core's rule for the account says.
      # Names: with names hidden one not signed in sees title and organization on a page, never in a mail, and someone
      # signed in sees the name; a person's own choice counts only where the organization allows it. Rolled back.
      ::GkScenarios::Expect.register('ppl_outward') do |ctx, e|
        av = ::GkPeople::Avatars
        af = ::GkPeople::AvatarFolder
        ow = ::GkPeople::Outward
        u = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['ppl_outward'].to_s))
        admin = ::User.active.where(admin: true).order(:id).first
        person = u && ::GkPeople.person_for(u)
        org = person&.organization
        next({ 'ok' => false, 'want' => 'a user with a person in an organization, and an administrator', 'got' => [u&.login, org&.name, admin&.login].map { |x| x || '-' }.join(', ') }) unless u && org && admin

        show = ->(who) { ctx.as(who) { ::IssuesController.renderer.render(inline: '<%= avatar(u, size: 24) %>', locals: { u: ::User.find(u.id) }) } }
        kind = lambda do |html|
          if html.include?('gk-people-avatar-folder') then 'folder'
          elsif html.include?('gk-people-avatar-icon') then 'icon'
          elsif html.include?('gk-people-avatar') then 'own'
          else 'core'
          end
        end
        settings_were = ::Setting.plugin_gk_people
        set = ->(h) { ::Setting.plugin_gk_people = (settings_were.is_a?(Hash) ? settings_were : {}).merge(h) }
        failed = []
        dir = ::Dir.mktmpdir('gk_people_outward')
        # GK Scenarios writes the settings back and empties core's cache of settings afterwards, also after the
        # rollback below
        ::GkScenarios::Expect.with_setting(:gk_people) do
          begin
            ::ActiveRecord::Base.transaction do
              scenario_feature!(av::FEATURE) # off for a new installation; rolled back with the rest
              ::Open3.capture3(av.convert_bin, '-size', '80x80', 'xc:#5c940d', "png:#{::File.join(dir, "#{u.login}.png")}")
              org.update_columns(avatar_folder_on: true, avatar_folder: dir, avatar_name_rule: 'login', avatar_hide_allowed: false, name_hide_allowed: false)
              png, = ::Open3.capture3(av.convert_bin, '-size', '64x64', 'xc:#1971c2', 'png:-', binmode: true)
              av.store(u, png, by: admin)
              af.forget!
              set.('avatar_order' => 'own_first')
              failed << "own first: #{kind.(show.(admin))}" unless kind.(show.(admin)) == 'own'
              set.('avatar_order' => 'folder_first')
              failed << "folder first: #{kind.(show.(admin))}" unless kind.(show.(admin)) == 'folder'
              org.update_columns(avatar_folder_on: false)
              af.forget!
              failed << "folder first, no folder: #{kind.(show.(admin))}" unless kind.(show.(admin)) == 'own'
              org.update_columns(avatar_folder_on: true)
              av.remove(u)
              set.('avatar_order' => 'own_first')
              pref = ::User.find(u.id).pref
              pref.gk_people_hide_folder_picture = '1'
              pref.save!
              af.forget!
              failed << "hidden, not allowed: #{kind.(show.(admin))}" unless kind.(show.(admin)) == 'folder'
              org.update_columns(avatar_hide_allowed: true)
              af.forget!
              failed << "hidden, allowed: #{kind.(show.(admin))}" unless kind.(show.(admin)) == 'core'
              pref.gk_people_hide_folder_picture = '0'
              pref.save!
              av.store(u, png, by: admin)
              set.('avatars_hide_anonymous' => '1')
              failed << 'anonymous saw a picture' unless kind.(show.(::User.anonymous)) == 'core'
              set.('avatars_hide_anonymous' => '0')
              core_says = ::GkPeople::Accounts.visible_account?(::User.find(u.id), ::User.anonymous)
              failed << "anonymous, pictures not hidden: #{kind.(show.(::User.anonymous))} (core: #{core_says})" unless (kind.(show.(::User.anonymous)) == 'own') == core_says
              real = ::User.find(u.id).firstname
              name_as = ->(who, mailing: false) { ow.with_request { ctx.as(who) { mailing ? ow.mailing { ::User.find(u.id).name } : ::User.find(u.id).name } } }
              set.('names_hide_anonymous' => '1')
              failed << "anonymous saw the name (#{name_as.(::User.anonymous)})" if name_as.(::User.anonymous).include?(real)
              failed << 'not title and organization' unless name_as.(::User.anonymous).include?(org.name)
              failed << 'hidden in a mail' unless name_as.(::User.anonymous, mailing: true).include?(real)
              failed << 'hidden from one signed in' unless name_as.(admin).include?(real)
              set.('names_hide_anonymous' => '0')
              pref.gk_people_hide_name = '1'
              pref.save!
              failed << 'own choice counted without the allowance' unless name_as.(::User.anonymous).include?(real)
              org.update_columns(name_hide_allowed: true)
              failed << 'own choice not counted with the allowance' if name_as.(::User.anonymous).include?(real)
              raise ::ActiveRecord::Rollback
            end
          ensure
            ::FileUtils.rm_rf(dir)
            af.forget!
            av.forget(u.id)
            ::GkRecords::Features.forget! if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
          end
        end
        want = 'order both ways; hiding only where allowed; pictures and names for those not signed in by the settings'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # ppl_review_content: true. What a review covers (records' Verification.content, which a signature is bound to)
      # is a chosen list of facts per kind (GkPeople::REVIEW_FACTS), never all the columns: the organization's text is
      # its facts in their order; a change to a column people keeps for itself (picture folder, the number's digits)
      # never changes it, a changed fact does; a group is covered by its name; and a target nobody chose content for
      # (a project) cannot be verified at all, nor have its status set. Rolled back.
      ::GkScenarios::Expect.register('ppl_review_content') do |_ctx, _e|
        v = defined?(::GkRecords::Verification) ? ::GkRecords::Verification : nil
        org = ::GkPeopleOrganization.order(:id).first
        next({ 'ok' => false, 'want' => 'records and an organization', 'got' => [v.nil? ? '-' : 'records', org&.id].inspect }) unless v && org

        failed = []
        text = v.content(org)
        facts = GkPeople::REVIEW_FACTS['organization']
        failed << 'not the facts in their order' unless text == facts.map { |n| "#{n}=#{org.public_send(n)}" }.join("\u0000")
        failed << 'own column in it' if %w[avatar_folder org_no_digits created_by_id updated_at].any? { |c| text.include?("#{c}=") }
        group = ::Group.givable.order(:id).first
        failed << 'group not covered by its name' if group && v.content(group) != "lastname=#{group.lastname}"
        project = ::Project.order(:id).first
        if project
          failed << 'a project can be verified' if v.verifiable?(project)
          refused = begin
            v.set!(project, 'unverified', user: ::User.active.where(admin: true).first)
            false
          rescue ArgumentError
            true
          end
          failed << 'a status set on a project' unless refused
        end
        # The places, where records knows them: people's row name and words by default (the locale's own), partly
        # verified on and hypothesis off for persons and organizations, the forced levels on every place, and the last
        # step by hand while people's review setting is off (as by default)
        vp = GkPeople::VerificationPlaces
        if vp.places?
          f = defined?(::GkFields::Translations) ? ::GkFields::Translations : nil
          lang = (f.respond_to?(:lang) ? f.lang : nil).presence || ::I18n.locale
          vp::PLACES.each do |place|
            failed << "#{place}: row name" unless vp.title(place) == ::I18n.t(vp.title_key(place), locale: lang)
            failed << "#{place}: word" unless vp.word('unverified', place) == ::I18n.t(vp.word_key(place, 'unverified'), locale: lang)
            lv = vp.levels(place)
            failed << "#{place}: forced levels" if lv && !(%w[none unverified verified] - lv).empty?
          end
          %w[person organization].each do |place|
            lv = vp.levels(place)
            failed << "#{place}: partly verified off" if lv && !lv.include?('partly_verified')
          end
          person = ::GkPeoplePerson.order(:id).first
          if person && v.respond_to?(:review_locked?) && !vp.review?('person')
            failed << 'a person locked to the review with the setting off' if v.review_locked?(person)
          end
        end
        ::ActiveRecord::Base.transaction do
          org.update_columns(avatar_folder_on: !org.avatar_folder_on, org_no_digits: '0', notes: "#{org.notes}x")
          failed << 'an own column or a note changed the content' unless v.content(::GkPeopleOrganization.find(org.id)) == text
          org.update_columns(city: "#{org.city}x")
          failed << 'a fact did not change the content' if v.content(::GkPeopleOrganization.find(org.id)) == text
          raise ::ActiveRecord::Rollback
        end
        want = 'the chosen facts only; a group by its name; a project not verifiable; the places with their words and levels'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # ppl_avatar_icon: <user key>, outsider: <user key>. An icon for any account: an icon the
      # library knows is drawn in its round field, the size asked, for the user and for a group; a name it does not know
      # is refused; an own picture goes before the icon, and the sources are asked own picture, icon, folder; the
      # outsider gets core's picture. Rolled back.
      ::GkScenarios::Expect.register('ppl_avatar_icon') do |ctx, e|
        av = ::GkPeople::Avatars
        ai = ::GkPeople::AvatarIcon
        u = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['ppl_avatar_icon'].to_s))
        outsider = e['outsider'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['outsider'].to_s))
        admin = ::User.active.where(admin: true).order(:id).first
        group = ::Group.givable.order(:id).first
        next({ 'ok' => false, 'want' => 'the icon library, a user, an outsider, an administrator and a group', 'got' => [ai.library?, u&.login, outsider&.login, admin&.login, group&.lastname].map { |x| x.nil? ? '-' : x.to_s }.join(', ') }) unless ai.library? && u && outsider && admin && group

        show = ->(who, whom, size = 24) { ctx.as(who) { ::IssuesController.renderer.render(inline: '<%= avatar(u, size: s) %>', locals: { u: whom, s: size }) } }
        reg = defined?(::Redmine::AvatarSources) ? ::Redmine::AvatarSources : ::GkCoreStuff::AvatarSources
        order = reg.sources.map(&:key).select { |k| k.to_s.start_with?('gk_people_') }.map(&:to_s)
        failed = []
        failed << "order #{order.join(' ')}" unless order == %w[gk_people_own_picture gk_people_icon_picture gk_people_folder_picture]
        begin
          ::ActiveRecord::Base.transaction do
            scenario_feature!(av::FEATURE) # off for a new installation; rolled back with the rest
            failed << 'a known icon refused' unless ai.set(u, 'user', by: admin)
            html = show.(admin, u, 24)
            failed << 'admin: no icon' unless html.include?('gk-people-avatar-icon') && html.include?('<svg') && html.include?('inline-size: 24px')
            failed << 'an unknown icon taken' if ai.set(u, 'gk-people-no-such-icon', by: admin)
            failed << 'outsider: the icon' if show.(outsider, u).include?('gk-people-avatar')
            png, = ::Open3.capture3(av.convert_bin, '-size', '64x64', 'xc:#e67700', 'png:-', binmode: true)
            av.store(u, png, by: admin)
            html = show.(admin, u)
            failed << 'own picture not before the icon' unless html.include?('gk-people-avatar') && !html.include?('gk-people-avatar-icon')
            av.remove(u)
            failed << 'group: no icon' unless ai.set(group, 'group', by: admin) && show.(admin, group).include?('gk-people-avatar-icon')
            ai.set(u, '', by: admin)
            failed << 'cleared: the icon' if show.(admin, u).include?('gk-people-avatar-icon')
            raise ::ActiveRecord::Rollback
          end
        ensure
          ai.forget(u.id)
          ai.forget(group.id)
          av.forget(u.id)
          ::GkRecords::Features.forget! if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
        end
        want = 'a known icon drawn for a user and a group; unknown refused; own first; outsider core'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # ppl_avatar_edit: <user key>, other: <user key>. Changing pictures. Who may: without a
      # permission no one but an administrator; with Byta egen bild only one's own; with Hantera bilder på personer
      # anyone's (global permissions through a role in a project, made here). What comes in: the small part from the
      # browser as a PNG data URL is made into the six sizes; anything but a PNG data URL, and bytes that are neither JPEG
      # nor PNG, are refused. The part of a folder picture: a part chosen on the right half gives another picture than
      # the middle, and the place, not the picture, is what is kept. Rolled back.
      ::GkScenarios::Expect.register('ppl_avatar_edit') do |ctx, e|
        av = ::GkPeople::Avatars
        af = ::GkPeople::AvatarFolder
        u = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['ppl_avatar_edit'].to_s))
        other = e['other'] && ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['other'].to_s))
        admin = ::User.active.where(admin: true).order(:id).first
        project = ::Project.active.order(:id).first
        org = u && ::GkPeoplePerson.where(user_id: u.id).first&.organization
        next({ 'ok' => false, 'want' => 'a user with an organization, another user, an administrator and a project', 'got' => [u&.login, other&.login, admin&.login, project&.identifier].map { |x| x || '-' }.join(', ') }) unless u && other && admin && project && org

        fresh = ->(x) { ::User.find(x.id) } # allowed_to? keeps the roles it has read
        # Alla får byta egen bild is given to may_edit? as the check goes, never written to the setting: core caches the
        # settings for every thread of the process, and another request could read the value in the middle of the check
        everyone = false
        may = ->(target, viewer) { av.may_edit?(target, fresh.(viewer), own_for_all: everyone) }
        failed = []
        dir = ::Dir.mktmpdir('gk_people_avatar_edit')
        begin
          ::ActiveRecord::Base.transaction do
            scenario_feature!(av::FEATURE) # off for a new installation; rolled back with the rest
            # The permissions first with Alla får byta egen bild off, so that only the permissions decide
            everyone = false
            failed << 'administrator may not' unless may.(u, admin)
            # Two accounts made here, members of nothing: the scenario's own roles (manager has every permission) never count
            fresh_account = lambda do |n|
              x = ::User.new(firstname: 'Bild', lastname: "Prov #{n}", mail: "gk-people-avatar-#{n}@example.invalid")
              x.login = "gk_people_avatar_#{n}"
              x.password = x.password_confirmation = "Gk1!#{::SecureRandom.hex(16)}"
              x.save!
              x
            end
            own = fresh_account.(1)
            mgr = fresh_account.(2)
            failed << 'no permission: may change own' if may.(own, own)
            failed << 'no permission: may change another' if may.(u, own)
            grant_role = ->(perm) { ::Role.create!(name: "gk_people_avatar_check_#{perm}", permissions: [perm], assignable: true) }
            grant =->(who, perm) { ::Member.create!(project: project, principal: who, roles: [grant_role.(perm)]) }
            grant.(own, :gk_people_change_own_avatar)
            failed << 'Byta egen bild: not own' unless may.(own, own)
            failed << 'Byta egen bild: another' if may.(u, own)
            grant.(mgr, :gk_people_manage_avatars)
            failed << 'Hantera bilder på personer: not another' unless may.(u, mgr)
            failed << 'Hantera bilder på personer: not a group' unless (g = ::Group.order(:id).first).nil? || may.(g, mgr)
            failed << 'anonymous' if may.(::User.anonymous, admin)
            # Alla får byta egen bild on (the default): her own without a permission, never another's
            other_own = fresh_account.(3)
            everyone = true
            failed << 'everyone: not own' unless may.(other_own, other_own)
            failed << 'everyone: another' if may.(u, other_own)

            png, = ::Open3.capture3(av.convert_bin, '-size', '256x256', 'xc:#8e44ad', 'png:-', binmode: true)
            bytes = av.from_data_url("data:image/png;base64,#{::Base64.strict_encode64(png)}")
            failed << 'PNG data URL not read' unless bytes == png
            failed << 'other data URL read' if av.from_data_url('data:image/svg+xml;base64,PHN2Zy8+')
            if bytes
              av.store(u, bytes, by: admin)
              failed << "sizes #{::GkPeopleAvatar.where(user_id: u.id).count}" unless ::GkPeopleAvatar.where(user_id: u.id).count == av::SIZES.size
            end
            refused = begin
              av.store(u, '<svg xmlns="http://www.w3.org/2000/svg"/>', by: admin)
              false
            rescue av::Error
              true
            end
            failed << 'SVG bytes taken' unless refused
            av.remove(u)

            path = ::File.join(dir, "#{u.login}.png")
            ::Open3.capture3(av.convert_bin, '-size', '100x200', 'gradient:#000000-#ffffff', '-rotate', '90', "png:#{path}")
            org.update_columns(avatar_folder_on: true, avatar_folder: dir, avatar_name_rule: 'login')
            af.forget!
            middle = af.picture(u, af.file_for(u), 24).checksum
            ::GkPeopleAvatarRegion.create!(user_id: u.id, x: 0.5, y: 0, s: 1, set_by_id: admin.id)
            af.forget!
            file = af.file_for(u)
            crop = file && af.crop_for(file)
            failed << "part #{crop.inspect}" unless crop == { x: 100, y: 0, w: 100, h: 100 }
            right = file && af.picture(u, file, 24).checksum
            failed << 'the part gives the same picture as the middle' if right.nil? || right == middle
            failed << 'the picture kept with the part' if ::GkPeopleAvatarRegion.column_names.any? { |c| c =~ /data|picture/ }
            # The page: the box for a new picture, and the box for the part with the folder's file under it
            page = ctx.as(admin) do
              ::GkPeopleAvatarsController.renderer.render(template: 'gk_people_avatars/edit', layout: false,
                                                          assigns: { principal: u, own: false, file: file, region: ::GkPeopleAvatarRegion.find_by(user_id: u.id) })
            end
            failed << 'page: no box for a new picture' unless page.include?('data-out-field="picture_data"')
            failed << 'page: no box for the part' unless page.include?("/gk_people/avatars/#{u.id}/original") && page.include?('name="middle"')
            # One form with one Save, as Redmine's own pages
            failed << "page: #{page.scan('type="submit"').size} save buttons" unless page.scan('type="submit"').size == 1
            raise ::ActiveRecord::Rollback
          end
        ensure
          ::FileUtils.rm_rf(dir)
          af.forget!
          av.forget(u.id)
          ::GkRecords::Features.forget! if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
        end
        want = 'who may change as the permissions say; only PNG data URLs, JPEG and PNG; the part changes the folder picture'
        { 'ok' => failed.empty?, 'want' => want, 'got' => failed.empty? ? want : "not: #{failed.join(', ')}" }
      end

      # ppl_today: "today" is the person's day (User#today), not UTC's or the server's: consents, credentials and
      # assignments that begin or end today or yesterday, on unsaved rows. Meant to run with in_zone, far from the server.
      ::GkScenarios::Expect.register('ppl_today') do |_ctx, _e|
        today = ::User.current.today
        failed = []
        failed << 'consent_from_today' unless ::GkPeopleConsent.new(given_on: today).state == :current
        failed << 'consent_ended_yesterday' unless ::GkPeopleConsent.new(given_on: today - 30, valid_to: today - 1).state == :expired
        failed << 'consent_ends_today' unless ::GkPeopleConsent.new(given_on: today - 30, valid_to: today).state == :current
        failed << 'credential_from_today' unless ::GkPeopleCredential.new(issued_on: today, valid_to: today + 365).status == :valid
        failed << 'credential_ended_yesterday' unless ::GkPeopleCredential.new(issued_on: today - 365, valid_to: today - 1).status == :expired
        failed << 'assignment_from_today' unless ::GkPeopleAssignment.new(valid_from: today).in_force?
        failed << 'assignment_ended_yesterday' unless ::GkPeopleAssignment.new(valid_from: today - 30, valid_to: today - 1).ended?
        failed << 'assignment_ends_today' if ::GkPeopleAssignment.new(valid_from: today - 30, valid_to: today).ended?
        { 'ok' => failed.empty?, 'want' => "the person's day #{today.iso8601}", 'got' => failed.empty? ? "the person's day #{today.iso8601}" : "not: #{failed.join(', ')}" }
      end

      # A person of the scenario as she is: organization (key), account (the scenario's user key), kind, the number of
      # identifiers in force; only the keys given are compared
      ::GkScenarios::Expect.register('person_is') do |ctx, e|
        p = scenario_person(ctx, e['person_is'])
        got = if p
                { 'organization' => p.organization&.name,
                  'account' => p.user&.login, 'kind' => p.kind, 'identifiers' => p.identifiers_in_force.size }
              else {}
              end
        want = e.slice('kind', 'identifiers')
        want['organization'] = ctx.scenario.t(:people, :organizations, e['organization'], :name) if e['organization']
        want['account'] = ::GkScenarios::Expect.login(ctx, e['account']) if e['account']
        { 'ok' => !p.nil? && want.all? { |k, v| got[k] == v }, 'want' => want.to_json, 'got' => (p ? got.slice(*want.keys).to_json : 'no person') }
      end

      # Looking up by an identifier finds the person (finds: the scenario's key; without it, nobody is found) (a token too, though it is kept only as digest and mask)
      ::GkScenarios::Expect.register('person_identified') do |ctx, e|
        found = Identify.lookup(e['person_identified'], e['value'].to_s)
        want = e['finds'] ? scenario_person(ctx, e['finds']) : nil
        ok = e['finds'] ? (!found.nil? && found.id == want&.id) : found.nil?
        { 'ok' => ok, 'want' => want&.name || '-', 'got' => found&.name || '-' }
      end

      # A click on a name (NameLinks): the chat program's link for the account as another sees it, with the page along
      # (app and icon of the scheme; contains: a piece of the link), or nothing (equals: false; hidden: the person hid it;
      # exposure: the administrator's off, optional or forced) Every check sets the state it needs and leaves it as it
      # was: the exposure is the given one or the plugin's default optional, for this thread only and never written to
      # Setting (NameLinks.with_exposure); the person's own choice is hidden or not hidden as the check says, read fresh
      # from the database and put back afterwards only when the check changed it.
      ::GkScenarios::Expect.register('ppl_name_link') do |ctx, e|
        viewer = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as'].to_s))
        user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['ppl_name_link'].to_s))
        iss = e['issue'] && ::GkScenarios::Expect.issue_for(ctx, e['issue'].to_s)
        url = iss ? "http://scenario.example/issues/#{iss.id}" : ''
        # hidden: the person has hidden her own chat link (Mitt konto), for this check only; otherwise not hidden
        pref = user&.pref
        before = pref && pref[:gk_people_hide_chat]
        hide_want = e['hidden'] == true ? '1' : '0'
        changed = pref && (before.to_s == '1' ? '1' : '0') != hide_want
        if changed
          pref[:gk_people_hide_chat] = hide_want
          pref.save!
        end
        begin
          link = if viewer && user
                   NameLinks.with_exposure(e['exposure'] || 'optional') do
                     NameLinks.for(viewer, [user.id], title: iss&.subject.to_s, url: url)[user.id]
                   end
                 end
        ensure
          if changed
            pref[:gk_people_hide_chat] = before
            pref.save!
          end
        end
        want = e.key?('equals') ? e['equals'] == true : true
        ok = if want
               !link.nil? && Array(e['contains']).all? { |c| link[:href].include?(c.to_s) } && (e['icon'].nil? || link[:icon] == e['icon']) &&
                 (url.empty? || link[:href].include?(ERB::Util.url_encode(url)))
             else link.nil?
             end
        { 'ok' => ok, 'want' => want ? "link #{Array(e['contains']).join(' ')} #{e['icon']}" : 'no link',
          'got' => link ? "#{link[:href].truncate(160)} #{link[:icon]}" : 'no link' }
      end

      ::GkScenarios::Steps.register('people_sync', plugin: :gk_people, order: 160) do |ctx|
        Array((ctx.scenario.data['people'] || {})['sync']).each_with_index do |call, i|
          by = ctx.get(:user, call['by'])
          src = call['source'].to_s
          ctx.as(by) do
            Sync::RESOURCES.each do |res|
              posts = call[res]
              next unless posts.is_a?(Array)
              raise "people sync #{res}: #{Sync.refuse(res, src, posts)[1]}" if Sync.refuse(res, src, posts)

              2.times do |pass|
                log = Sync.run(res, src, posts.map { |x| x.transform_keys(&:to_s) })
                ctx.note(:people_sync, "#{i}.#{res}.#{pass}", log, log.created.positive?)
              end
            end
          end
        end
      end

      # people_import: imports from CSV as the person named, through the same two steps as the page (people.imports: key,
      # resource, by, mode, source_on as days from today, and run: false for a preview only). The file and the source are
      # text in the locale (people.imports.<key>.csv and.source), since they hold names.
      ::GkScenarios::Steps.register('people_import', plugin: :gk_people, order: 165) do |ctx|
        # Imports run before readings existed get theirs in hindsight (once; also from after_initialize)
        ReadingBackfill.run_once!
        Array((ctx.scenario.data['people'] || {})['imports']).each do |im|

          by = ctx.get(:user, im['by'])
          # File: the file's name (default <key>.csv), manifest: the source's manifest (import_manifest)
          bytes = ctx.scenario.t(:people, :imports, im['key'], :csv)
          filename = im['file'].presence || "#{im['key']}.csv"
          ctx.as(by) do
            imp = Import.start!(resource: im['resource'], bytes: bytes,
                                source_label: ctx.scenario.t(:people, :imports, im['key'], :source),
                                source_on: (im['source_on'] ? ctx.day(im['source_on']) : nil), mode: im['mode'] || 'fill',
                                filename: filename, user: by, manifest: import_manifest(ctx, im, bytes, filename))
            Import.run!(imp, user: by) unless im['run'] == false
            ctx.note(:people_import, im['key'], imp, true)
          end
        end
      end

      # The latest import with the source of the scenario's import: its state and what it did (only the counts given:
      # new, update, unchanged, skipped, rejected), and the lines rejected
      ::GkScenarios::Expect.register('ppl_import') do |ctx, e|
        label = ctx.scenario.t(:people, :imports, e['ppl_import'], :source)
        imp = ::GkPeopleImport.where(source_label: label).sorted.first
        want = (e['counts'] || {}).transform_keys(&:to_s)
        want['state'] = e['state'] || 'done'
        got = imp ? imp.counts.slice(*want.keys).merge('state' => imp.state) : {}
        if e.key?('rejected_lines')
          want['rejected_lines'] = Array(e['rejected_lines'])
          got['rejected_lines'] = imp ? imp.preview_rows.select { |r| r['action'] == 'rejected' }.map { |r| r['line'] } : []
        end
        if e.key?('manifest')
          want['manifest'] = e['manifest'] == true
          rd = imp&.reading
          m = rd ? rd.manifest : imp&.manifest
          entry = m.is_a?(Hash) && imp ? Array(m['files']).detect { |f| f.is_a?(Hash) && f['file'].to_s.casecmp?(File.basename(imp.filename.to_s)) } : nil
          got['manifest'] = !entry.nil? && !m.key?('computer') && (rd.nil? || entry['sha256'].to_s == rd.files.first&.dig('sha256').to_s)
        end
        { 'ok' => !imp.nil? && got == want, 'want' => want.to_json, 'got' => imp ? got.to_json : 'no import' }
      end

      # An organization as it is: found by the scenario's key or by its organization number (digits); its kinds,
      # where its facts come from (from: the scenario's import key), whether it has an address, its name, and
      # whether its last event came from an import
      ::GkScenarios::Expect.register('org_is') do |ctx, e|
        org = if e['org_is'].to_s.match?(/\A[\d\-\s]+\z/)
                digits = e['org_is'].to_s.gsub(/\D/, '')
                ::GkPeopleOrganization.by_number(digits).order(:id).first
              else
                scenario_org(ctx, e['org_is'])
              end
        want = {}
        got = {}
        if e.key?('kinds')
          want['kinds'] = Array(e['kinds']).map(&:to_s).sort
          got['kinds'] = org&.kind_keys.to_a.sort
        end
        if e.key?('from')
          want['info_source'] = ctx.scenario.t(:people, :imports, e['from'], :source)
          got['info_source'] = facts_from(org, want['info_source'])
        end
        if e.key?('address')

          want['address'] = e['address'] == true ? true : e['address'].to_s
          got['address'] = e['address'] == true ? org&.address.present? : org&.address.to_s
        end
        if e.key?('name')
          want['name'] = ctx.scenario.t(:people, :organizations, e['name'], :name)
          got['name'] = org&.name
        end
        # Place, SNI and the row's own source and date, as the file wrote them
        %w[city sni info_source info_source_on].each do |f|
          next unless e.key?(f)

          want[f] = e[f].to_s
          got[f] = org&.public_send(f).to_s
        end
        if e.key?('imported') && defined?(::GkRecordsEvent)
          # the import's own event, not the newest: relations, tags and statuses may come after it
          evs = org ? ::GkRecordsEvent.where(target_type: 'organization', target_id: org.id, origin: 'import').order(:id).to_a : []
          want['imported'] = e['imported']
          got['imported'] = evs.any? { |ev| ev.details_hash['imported'].is_a?(Hash) }
        end
        { 'ok' => !org.nil? && got == want, 'want' => want.to_json, 'got' => org ? got.to_json : 'no organization' }
      end

      # A person found by her e-mail: her organization (organization number), where her facts come from
      ::GkScenarios::Expect.register('person_by_email') do |ctx, e|
        p = ::GkPeoplePerson.where('lower(email) = lower(?)', e['person_by_email'].to_s).order(:id).first
        want = {}
        got = {}
        if e.key?('org_no')
          want['org_no'] = e['org_no'].to_s.gsub(/\D/, '')
          got['org_no'] = p&.organization&.org_no.to_s.gsub(/\D/, '')
        end
        if e.key?('from')
          want['info_source'] = ctx.scenario.t(:people, :imports, e['from'], :source)
          got['info_source'] = facts_from(p, want['info_source'])
        end

        %w[display_name].each do |f|
          next unless e.key?(f)

          want[f] = e[f].to_s
          got[f] = p&.public_send(f).to_s
        end
        if e.key?('title')
          want['title'] = true
          got['title'] = p&.title.present?
        end
        { 'ok' => !p.nil? && got == want, 'want' => want.to_json, 'got' => p ? got.to_json : 'no person' }
      end

      # A post from the source is here with what the source said (has: fields; organization: its external id;
      # active), and its last event says it came from the source (origin synced)
      ::GkScenarios::Expect.register('people_synced') do |_ctx, e|
        model = { 'organizations' => ::GkPeopleOrganization, 'persons' => ::GkPeoplePerson, 'groups' => ::GkPeopleGroup }.fetch(e['people_synced'].to_s)
        row = model.find_by(source: e['source'].to_s, external_id: e['external_id'].to_s)
        bad = []
        if row
          (e['has'] || {}).each { |k, v| bad << "#{k}: #{row[k].inspect}" unless row[k].to_s == v.to_s }
          if e.key?('organization')
            bad << "organization: #{row.organization&.external_id.inspect}" unless row.organization&.external_id.to_s == e['organization'].to_s
          end
          bad << "active: #{row.active}" if e.key?('active') && row.active != e['active']
          bad << 'not locked' unless row.owned_by_source?(row.is_a?(::GkPeopleGroup) ? :name : (row.is_a?(::GkPeoplePerson) ? :email : :name))
          if e.key?('members')
            got = row.memberships.includes(:person).map { |m| m.person.external_id }.sort
            bad << "members: #{got.join(', ')}" unless got == Array(e['members']).map(&:to_s).sort
          end
          if defined?(::GkRecordsEvent) && !row.is_a?(::GkPeopleGroup)
            ev = ::GkRecordsEvent.where(target_type: (row.is_a?(::GkPeoplePerson) ? 'person' : 'organization'), target_id: row.id).order(:id).last
            bad << "last event origin: #{ev&.origin.inspect}" unless ev&.origin == 'synced'
          end
        end
        { 'ok' => !row.nil? && bad.empty?, 'want' => e.except('key').to_json, 'got' => row ? (bad.empty? ? 'as sent' : bad.join('; ')) : 'missing' }
      end

      # The second call with the same posts changes nothing, and the posts that are wrong are rejected by external id
      ::GkScenarios::Expect.register('people_sync_calls') do |_ctx, e|
        logs = ::GkPeopleSyncLog.where(source: e['source'].to_s, resource: e['people_sync_calls'].to_s).sorted.limit(2).to_a
        last = logs.first
        bad = []
        bad << 'fewer than two calls' if logs.size < 2
        bad << "second call: created #{last.created}, updated #{last.updated}" if last && (last.created + last.updated).positive?
        rejected = last ? last.errors_list.map { |x| x['external_id'].to_s }.sort : []
        bad << "rejected: #{rejected.join(', ')}" unless rejected == Array(e['rejected']).map(&:to_s).sort
        { 'ok' => bad.empty?, 'want' => { 'second' => 'unchanged', 'rejected' => e['rejected'] }.to_json, 'got' => bad.empty? ? 'ok' : bad.join('; ') }
      end

      # A token is never kept in clear text
      ::GkScenarios::Expect.register('token_hidden') do |ctx, e|
        p = scenario_person(ctx, e['token_hidden'])
        rows = p ? p.identifiers.joins(:scheme).where(gk_people_schemes: { kind: 'token' }).to_a : []
        clear = rows.select { |i| i.value.to_s == e['value'].to_s || i.value_digest.blank? }
        { 'ok' => rows.any? && clear.empty?, 'want' => 'digest and mask', 'got' => rows.empty? ? 'no token' : rows.map(&:value).join(', ') }
      end

      # Who may do what with the registers: view, manage or manage_identifiers (equals: false for may not)
      ::GkScenarios::Expect.register('people_may') do |ctx, e|
        user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['people_may']))
        got = if user.nil? then false
              elsif e['can'].to_s == 'sync' then Sync.allowed?(user)
              elsif e['can'].to_s == 'responsibilities' then Responsibilities.manage?(user)
              elsif e['can'].to_s == 'credentials' then Credentials.manage?(user)
              else Access.send({ 'view' => :view?, 'manage' => :manage?, 'manage_identifiers' => :identifiers? }.fetch(e['can'].to_s), user)
              end
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # An account made after people is there gets its person by itself (create_person_on_user)
      ::GkScenarios::Expect.register('account_has_person') do |ctx, e|
        user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['account_has_person']))
        p = user && GkPeople.person_for(user)
        { 'ok' => !p.nil?, 'want' => 'person', 'got' => p ? p.name : '-' }
      end

      # A group of people has exactly these members (the scenario's person keys), asked through the Ruby API by its name
      ::GkScenarios::Expect.register('person_group') do |ctx, e|
        name = ctx.scenario.t(:people, :groups, e['person_group'], :name)
        got = Api.group_members(name).map(&:id).sort
        want = Array(e['members']).map { |k| scenario_person(ctx, k)&.id }.compact.sort
        { 'ok' => got == want && want.size == Array(e['members']).size, 'want' => want.to_json, 'got' => got.to_json }
      end

      # The search (Ruby API, the persons list and autocomplete) finds the person for a term
      ::GkScenarios::Expect.register('people_search') do |ctx, e|
        found = Api.search(e['people_search'].to_s)
        want = scenario_person(ctx, e['finds'])
        { 'ok' => !want.nil? && found.any? { |p| p.id == want.id }, 'want' => want&.name || '-', 'got' => found.map(&:name).join(', ').presence || '-' }
      end

      # Every table with personal data that the owners given keep has a purpose (the record of processing)
      ::GkScenarios::Expect.register('processing_complete') do |_ctx, e|
        missing = Processing.missing(owners: e['processing_complete']).map(&:table)
        { 'ok' => missing.empty?, 'want' => 'no table without a purpose', 'got' => missing.empty? ? 'none' : missing.join(', ') }
      end

      # What the organization wrote over the declaration for a table is what the record shows
      ::GkScenarios::Expect.register('processing_written') do |ctx, e|
        entry = Processing.entry(e['processing_written'])
        texts = ctx.scenario.t?(:people, :processing, e['processing_written']) || {}
        want = texts.slice('purpose', 'retention', 'visible_to')
        got = entry ? want.keys.to_h { |k| [k, entry.public_send(k)] } : {}
        { 'ok' => !entry.nil? && entry.written? && want.all? { |k, v| got[k] == v }, 'want' => want.to_json, 'got' => entry ? got.to_json : 'no table' }
      end

      # A person's extract: the tables it has (with at least so many rows), the tables it lacks, and the columns it
      # never shows (table.column). Made without logging (the page logs; a check does not)
      ::GkScenarios::Expect.register('subject_access') do |ctx, e|
        p = scenario_person(ctx, e['subject_access'])
        parts = p ? SubjectAccess.extract(p) : []
        by = parts.index_by { |part| part.entry.table }
        got = by.transform_values(&:count)
        bad = []
        (e['has'] || {}).each { |t, n| bad << "#{t}: #{got[t.to_s].to_i} < #{n}" if got[t.to_s].to_i < n.to_i }
        Array(e['lacks']).each { |t| bad << "#{t}: #{got[t.to_s]}" if got.key?(t.to_s) }
        # what is another's is never shown: in a table about persons (person_id), a row about someone else that she only
        # did something in shows that column as another's
        Array(e['others_hidden']).each do |tc|
          t, c = tc.to_s.split('.', 2)
          part = by[t]
          i = part&.columns&.index(c)
          pi = part&.columns&.index('person_id')
          others = part && i && pi ? part.rows.reject { |r| r[pi].to_s == p.id.to_s } : []
          bad << "#{tc}: no row of another's" if others.empty?
          bad << "#{tc}: another's shown" if others.any? { |r| r[i] != :other }
        end
        { 'ok' => !p.nil? && bad.empty?, 'want' => { 'has' => e['has'], 'lacks' => e['lacks'], 'hidden' => e['hidden'], 'others_hidden' => e['others_hidden'] }.compact.to_json,
          'got' => p ? (bad.empty? ? got.slice(*(e['has'] || {}).keys.map(&:to_s)).to_json : bad.join('; ')) : 'no person' }
      end

      register_group_scenarios!
      register_actor_scenarios!
      register_responsibility_scenarios!
      register_credential_scenarios!
      register_role_sync_scenarios!
      register_reading_scenarios!
      register_quick_scenarios!
      register_company_data_scenarios!
    end

    # An organization's place in the step people: address and city as text in the locale
    # (people.organizations.<key>.address and.city, since they hold names), the coordinates as numbers in scenario.yml
    # (location_n and location_e, with location_crs when they are not SWEREF 99 TM, EPSG:3006). Only what the organization
    # does not have yet is set.
    def self.place!(ctx, org, o)
      texts = ctx.scenario.t?(:people, :organizations, o['key'])
      texts = {} unless texts.is_a?(Hash)
      org.address = texts['address'].to_s if org.address.blank? && texts['address'].present?
      org.city = texts['city'].to_s if org.city.blank? && texts['city'].present?
      return unless org.has_attribute?(:location_n) && o.key?('location_n') && o.key?('location_e')
      return unless org.location_n.nil? && org.location_e.nil?

      org.location_n = o['location_n']
      org.location_e = o['location_e']
      org.location_crs = o['location_crs'].to_s if o['location_crs']
    end

    def self.scenario_person(ctx, key)
      p = ctx.made['person'][key.to_s]
      return p.reload if p

      pr = Array((ctx.scenario.data['people'] || {})['persons']).detect { |x| x['key'] == key.to_s }
      unless pr
        # an account of the scenario without its own line under people.persons: the person behind the account
        u = ctx.scenario.list(:users).detect { |x| x['key'] == key.to_s }
        return u && (user = ::User.find_by(login: u['login'])) ? GkPeople.person_for(user) : nil
      end

      if pr['user']
        user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, pr['user']))
        user && GkPeople.person_for(user)
      else
        ::GkPeoplePerson.find_by(first_name: ctx.scenario.t(:people, :persons, key, :first_name), last_name: ctx.scenario.t(:people, :persons, key, :last_name))
      end
    end
  end
end

module GkPeople
  module Scenarios
    # The group's step and expectation in scenarios: a group's texts (What the group does, Authority) from the
    # scenario's locale, written as the person the scenario names, and the expectation that a section has a text
    def self.register_group_scenarios!
      ::GkScenarios::Steps.register('group_texts', plugin: :gk_people, order: 300) do |ctx|
        next unless Groups.ready?

        ctx.scenario.list(:groups).each do |g|
          group = ctx.get(:group, g['key'])
          { 'group_purpose' => :purpose, 'group_authority' => :authority }.each do |kind, text_key|
            text = ctx.scenario.t?(:groups, g['key'], text_key)
            next if text.blank?

            existing = Groups.current(group, kind)
            unless existing
              by = ctx.get(:user, g['written_by'])
              existing = ::GkRecordsNote.create!(target_type: Groups::TARGET, target_id: group.id, kind: kind, body: text, user_id: by.id, origin: 'human')
              ctx.note(:group_text, "#{g['key']}.#{text_key}", existing, true)
              next
            end
            ctx.note(:group_text, "#{g['key']}.#{text_key}", existing, false)
          end
        end
      end
      ::GkScenarios::Expect.register('group_text') do |ctx, e|
        g = ctx.scenario.list(:groups).detect { |x| x['key'] == e['group_text'] }
        group = g && ::Group.givable.find_by(lastname: ctx.scenario.t(:groups, g['key'], :name))
        note = group && Groups.current(group, "group_#{e['section']}")
        { 'ok' => !note.nil?, 'want' => e['section'].to_s, 'got' => note ? 'text' : '-' }
      end
    end
  end
end

module GkPeople
  module Scenarios
    # actor_records in scenarios (people.shared): the group of shared accounts, the accounts, and notes registered on
    # them with a person; expectations that the account is shared and has no person, that a save needs an active
    # internal person, and that a note carries who wrote it The plugin's settings as stored in the database. A step
    # that changes one key writes the whole hash back; core's cache of settings is one hash shared by the process's
    # threads, so a copy read from it can be older than the database and would undo a change made meanwhile.
    # Read as core's own Setting.find_or_default does (a private class method in Redmine 6.0, 6.1 and 7.0): the newest
    # stored row, whose Setting#value unserializes it, else the plugin's default as core registered it
    # (Setting.available_settings), so the keys have the same form as Setting.plugin_gk_people gives.
    def self.stored_settings
      row = ::Setting.where(name: 'plugin_gk_people').order(id: :desc).first
      v = row ? row.value : (::Setting.available_settings['plugin_gk_people'] || {})['default']
      v.is_a?(Hash) ? v.deep_dup : {}
    end

    def self.shared_data(ctx) = ((ctx.scenario.data['people'] || {})['shared'] || {})

    def self.shared_login(ctx, key)
      a = Array(shared_data(ctx)['accounts']).detect { |x| x['key'] == key.to_s }
      a ? a['login'] : ::GkScenarios::Expect.login(ctx, key)
    end

    # The account of a people.avatars row: a user, a shared account (people.shared.accounts) or a group
    # Found by login and name, so a check without Skapa in the same run finds them too
    def self.avatar_target(ctx, a)
      found = lambda do |x, what|
        raise ::GkScenarios::Error, "people avatars: no #{what}" unless x

        x
      end
      if a['user']
        [found.(::User.find_by(login: ::GkScenarios::Expect.login(ctx, a['user'])), "user #{a['user']}"), "user:#{a['user']}"]
      elsif a['group']
        [found.(::Group.givable.find_by(lastname: ctx.scenario.t(:groups, a['group'], :name)), "group #{a['group']}"), "group:#{a['group']}"]
      elsif a['shared']
        user = ::User.find_by_login(shared_login(ctx, a['shared']))
        raise ::GkScenarios::Error, "people avatars: no shared account #{a['shared']}" unless user

        [user, "shared:#{a['shared']}"]
      else raise ::GkScenarios::Error, 'people avatars: user, shared or group'
      end
    end

    def self.register_actor_scenarios!
      ::GkScenarios::Steps.register('people_shared', plugin: :gk_people, order: 170) do |ctx|
        sh = shared_data(ctx)
        next if sh.empty? || !Actor.ready?

        s = ctx.scenario
        name = s.t(:people, :shared, :group)
        group = ::Group.givable.find_by(lastname: name)
        created = group.nil?
        group ||= ::Group.create!(lastname: name)
        ctx.note(:shared_group, 'group', group, created)
        # the setting names the group, unless it already names another group that is there (read from the database,
        # not core's shared cache, so that an old value there is never written back)
        stored = stored_settings
        gid = stored['actor_group_id'].to_i
        ::Setting.plugin_gk_people = stored.merge('actor_group_id' => group.id.to_s) unless gid.positive? && ::Group.givable.exists?(id: gid)
        Array(sh['accounts']).each do |a|
          user = ::User.find_by_login(a['login'])
          made = user.nil?
          if user
            ::GkScenarios::Steps.save_person(user) if ::GkScenarios::Steps.instance_password!(user)
          else
            user = ::User.new(firstname: s.t(:people, :shared, :accounts, a['key'], :firstname), lastname: s.t(:people, :shared, :accounts, a['key'], :lastname),
                              mail: "#{a['login']}@example.invalid", language: s.locale)
            user.login = a['login']
            ::GkScenarios::Steps.instance_password!(user)
            Actor.creating_shared { ::GkScenarios::Steps.save_person(user) }
          end
          group.users << user unless group.users.include?(user)
          ctx.note(:user, a['key'], user, made)
        end
        # the group is a member where the shared computers register (its accounts follow it); its roles are the ceiling
        Array(sh['members']).each do |m|
          project = ctx.get(:project, m['project'])
          want = Array(m['roles']).map { |r| ctx.get(:role, r).id }
          member = ::Member.find_by(project_id: project.id, user_id: group.id)
          if member.nil?
            ::Member.create!(project: project, principal: group, role_ids: want)
            ctx.note(:shared_member, m['project'], project, true)
          elsif (want - member.role_ids).any?
            member.role_ids = (member.role_ids + want).uniq
            member.save!
            ctx.note(:shared_member, m['project'], project, true)
          end
        end
        # the matrix: who stands at each computer and what each may do there (people groups and persons by their keys)
        Array(sh['accounts']).each do |a|
          user = ctx.get(:user, a['key'])
          list = Array(a['matrix']).flat_map do |row|
            t, pid = if row['group'] then ['group', ::GkPeopleGroup.find_by(name: s.t(:people, :groups, row['group'], :name))&.id]
                     else ['person', scenario_person(ctx, row['person'])&.id]
                     end
            next [] unless pid

            project = ctx.get(:project, row['project'])
            Array(row['roles']).map { |r| [t, pid, project.id, ctx.get(:role, r).id] }
          end
          before = Actor.rows(user).count
          Actor.set_matrix!(user, Actor.rows(user).pluck(:principal_type, :principal_id, :project_id, :role_id) + list) if list.any?
          ctx.note(:shared_matrix, a['key'], user, Actor.rows(user).count > before)
          SharedAccounts.set_require_pin!(user, a['require_pin'] == true) if a.key?('require_pin') && SharedAccounts.ready?
        end
        # PINs as the persons would have set them themselves
        Array(sh['pins']).each do |pn|
          person = scenario_person(ctx, pn['person'])
          next unless person && Pin.ready?
          next ctx.note(:pin, pn['person'], person, false) if Pin.set?(person) && Pin.matches?(person.pin_digest, pn['pin'].to_s)

          Pin.set!(person, pn['pin'].to_s, by: pn['by'] || 'self')
          ctx.note(:pin, pn['person'], person.reload, true)
        end
      end

      ::GkScenarios::Steps.register('people_shared_records', plugin: :gk_people, order: 480) do |ctx|
        next unless Actor.ready?

        Array(shared_data(ctx)['records']).each do |r|
          account = ctx.get(:user, r['account'])
          person = scenario_person(ctx, r['person'])
          issue = ctx.get(:issue, r['issue'])
          text = ctx.scenario.t(:people, :shared, :notes, r['key'])
          rec = ::GkPeopleActorRecord.joins(:journal).where(issue_id: issue.id, person_id: person.id, user_id: account.id)
                                   .where(journals: { notes: text }).first
          unless rec
            fresh = ::Issue.find(issue.id)
            ctx.as(account) do
              Actor.as_person(person, captured_by: 'search') do
                fresh.init_journal(account, text)
                fresh.save!
              end
            end
            rec = ::GkPeopleActorRecord.where(issue_id: issue.id, user_id: account.id).order(:id).last
            at = ctx.day(r['at'] || 0).to_time + 11.hours
            rec&.journal&.update_columns(created_on: at)
            rec&.update_columns(captured_at: at)
            ctx.note(:actor_record, r['key'], rec, true)
            next
          end
          ctx.note(:actor_record, r['key'], rec, false)
        end
      end

      # The account is shared (equals: false for one that is not)
      ::GkScenarios::Expect.register('actor_shared') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_shared']))
        got = !user.nil? && Actor.shared?(user)
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # A shared account is a computer: no person of its own
      ::GkScenarios::Expect.register('actor_no_person') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_no_person']))
        p = user && GkPeople.person_for(user)
        { 'ok' => !user.nil? && p.nil?, 'want' => 'no person', 'got' => user ? (p ? p.name : 'no person') : 'no account' }
      end

      # An issue on the shared account saves only with an active internal person (person: none for no person)
      ::GkScenarios::Expect.register('actor_save') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_save']))
        project = ::Project.find_by(id: ::GkScenarios::Expect.project_id(ctx, e['project']))
        tracker = ::Tracker.find_by(name: ctx.scenario.t(:trackers, e['tracker']))
        person = e['person'] && e['person'] != 'none' ? scenario_person(ctx, e['person']) : nil
        issue = ::Issue.new(project: project, tracker: tracker, author: user, subject: 'actor_save', priority: ::IssuePriority.default || ::IssuePriority.first)
        issue.status = tracker&.default_status
        errs = []
        ok_save = false
        ctx.as(user) do
          Actor.as_person(person) do
            ok_save = issue.valid?
            errs = issue.errors.full_messages
          end
        end
        mine = [::I18n.t(:error_gk_people_actor_missing), ::I18n.t(:error_gk_people_actor_not_choosable), ::I18n.t(:error_gk_people_actor_no_groups)]
        refused = (errs & mine).any?
        want = e.key?('saves') ? e['saves'] : true
        ok = want ? (ok_save && !refused) : (!ok_save && refused)
        { 'ok' => ok, 'want' => want ? 'saves' : 'refused', 'got' => ok_save ? 'saves' : (errs.join('; ').presence || 'refused') }
      end

      # Logging time on the shared account without a person is refused with the reason (core may refuse it for other
      # reasons too, such as a role without log_time; only the reason from people is asked about here)
      ::GkScenarios::Expect.register('actor_time') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_time']))
        project = ::Project.find_by(id: ::GkScenarios::Expect.project_id(ctx, e['project']))
        person = e['person'] && e['person'] != 'none' ? scenario_person(ctx, e['person']) : nil
        te = ::TimeEntry.new(project: project, user: user, author: user, hours: 1, spent_on: ::User.current.today,
                             activity: ::TimeEntryActivity.default || ::TimeEntryActivity.active.first)
        errs = []
        ctx.as(user) { Actor.as_person(person) { te.valid?; errs = te.errors.full_messages } }
        mine = [::I18n.t(:error_gk_people_actor_missing), ::I18n.t(:error_gk_people_actor_not_choosable), ::I18n.t(:error_gk_people_actor_no_groups)]
        refused = (errs & mine).any?
        want = e.key?('refused') ? e['refused'] : true
        { 'ok' => refused == want, 'want' => want ? 'refused by people' : 'not refused by people', 'got' => errs.join('; ').presence || 'valid' }
      end

      # What a person at the shared computer may do in a project (person: none for nobody chosen): the matrix, with the
      # account's own roles as the ceiling
      ::GkScenarios::Expect.register('actor_may') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_may']))
        project = ::Project.find_by(id: ::GkScenarios::Expect.project_id(ctx, e['project']))
        person = e['person'] && e['person'] != 'none' ? scenario_person(ctx, e['person']) : nil
        issue = e['issue'] ? ::GkScenarios::Expect.issue_for(ctx, e['issue']) : nil   # per tracker, as core asks on an issue
        got = user && project ? Actor.may?(user, person, e['permission'], project, issue: issue) : false
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => got == want, 'want' => want.to_s, 'got' => got.to_s }
      end

      # A badge read at the shared computer: who it is (finds: none for an unknown badge), and whether she stands there
      ::GkScenarios::Expect.register('actor_badge') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_badge']))
        person, = Identify.by_token(e['value'].to_s)
        want = e['finds'].to_s == 'none' ? nil : scenario_person(ctx, e['finds'])
        here = person && user ? Actor.choosable?(person, user) : false
        want_here = e.key?('here') ? e['here'] : !want.nil?
        ok = person&.id == want&.id && here == want_here
        { 'ok' => ok, 'want' => "#{want&.name || '-'}#{want_here ? ', here' : ''}", 'got' => "#{person&.name || '-'}#{here ? ', here' : ''}" }
      end

      # A PIN matches what the person set (without counting a wrong try), and is kept only as a hash
      ::GkScenarios::Expect.register('pin_check') do |ctx, e|
        person = scenario_person(ctx, e['pin_check'])
        got = person && Pin.set?(person) ? Pin.matches?(person.pin_digest, e['pin'].to_s) : false
        hashed = person.nil? || (person.pin_digest.to_s.start_with?('pbkdf2_sha256$') && person.pin_digest != e['pin'].to_s)
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => got == want && hashed, 'want' => "#{want}, hashed", 'got' => "#{got}#{hashed ? ', hashed' : ', NOT hashed'}" }
      end

      # Exactly these persons can be chosen at the shared account (the members of its groups, active and internal)
      ::GkScenarios::Expect.register('actor_choosable') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['actor_choosable']))
        got = user ? Actor.choosable(user).sorted.map(&:name) : []
        want = Array(e['persons']).map { |k| scenario_person(ctx, k)&.name }.compact.sort
        { 'ok' => !user.nil? && got.sort == want, 'want' => want.join(', '), 'got' => got.join(', ').presence || '-' }
      end

      # A note on the issue was registered on the shared account by the person, and says so
      ::GkScenarios::Expect.register('actor_recorded') do |ctx, e|
        user = ::User.find_by(login: shared_login(ctx, e['account']))
        person = scenario_person(ctx, e['person'])
        issue = ::GkScenarios::Expect.issue_for(ctx, e['issue'])
        text = ctx.scenario.t(:people, :shared, :notes, e['actor_recorded'])
        rec = issue && user && ::GkPeopleActorRecord.joins(:journal).where(issue_id: issue.id, user_id: user.id).where(journals: { notes: text }).first
        bad = []
        bad << 'no record' unless rec
        bad << "person: #{rec.person&.name}" if rec && rec.person_id != person&.id
        bad << "journal by #{rec.journal.user&.login}" if rec && rec.journal.user_id != user.id
        { 'ok' => bad.empty?, 'want' => "#{person&.name} via #{user&.login}", 'got' => bad.empty? ? 'recorded' : bad.join('; ') }
      end
    end
  end
end

module GkPeople
  module Scenarios
    # responsibilities in scenarios (people.responsibilities and people.assignments): the responsibilities (names and
    # descriptions in the locale), and who held them when, in which scope, with which deputy; days are relative to
    # today. Expectations: who acts on a day in a scope (holder, deputy, fallback to the organization, vacancy), how
    # many hold an area, and that a function takes no second holder.
    def self.resp_scope(ctx, sc)
      return nil if sc.nil?
      return ctx.get(:project, sc['project']) if sc['project']

      ['group', ::GkPeopleGroup.find_by(name: ctx.scenario.t(:people, :groups, sc['group'], :name))&.id]
    end

    def self.resp_scope_check(ctx, sc)
      return nil if sc.nil?
      return ::Project.find_by(id: ::GkScenarios::Expect.project_id(ctx, sc['project'])) if sc['project']

      resp_scope(ctx, sc)
    end

    # A step that goes through a function off for a new installation switches it on first (an event in records with
    # the reason scenario), so the expectations see what an administrator who switched it on would see
    def self.scenario_feature!(key)
      return false unless defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register) && ::GkRecords::Features.find(key)
      return false if ::GkRecords::Features.on?(key)

      ::GkRecords::Features.set!(key, true, reason: 'scenario')
      true
    end

    def self.register_responsibility_scenarios!
      ::GkScenarios::Steps.register('people_responsibilities', plugin: :gk_people, order: 175) do |ctx|
        next unless Responsibilities.ready?

        data = ctx.scenario.data['people'] || {}
        # the job people_role_sync and the invariant responsibility_vacant (ops' expectations) are there only while
        # people.responsibilities is on
        if Array(data['responsibilities']).any? || (data['role_sync'] || {}).any?
          ctx.note(:feature, 'people.responsibilities', nil, scenario_feature!('people.responsibilities'))
          RoleSync.ops_registrations!(force: true)
        end
        Array(data['responsibilities']).each_with_index do |r, i|
          row = ::GkPeopleResponsibility.find_by(key: r['key'])
          made = row.nil?
          row ||= ::GkPeopleResponsibility.create!(key: r['key'], name: ctx.scenario.t(:people, :responsibilities, r['key'], :name),
                                                 description: ctx.scenario.t?(:people, :responsibilities, r['key'], :description),
                                                 kind: r['kind'] || 'function', position: (i + 1) * 10)
          if r.key?('requires') && Credentials.ready? && Credentials.required_keys(row) != Array(r['requires']).map(&:to_s)
            Credentials.set_required!(row, r['requires'])
            row.save!
          end
          ctx.note(:responsibility, r['key'], row, made)
        end
        Array(data['assignments']).each_with_index do |a, i|
          resp = ::GkPeopleResponsibility.find_by(key: a['responsibility'])
          person = scenario_person(ctx, a['person'])
          next unless resp && person

          type, sid = Responsibilities.scope_of(resp_scope(ctx, a['scope']))
          from = a.key?('from') ? ctx.day(a['from']) : nil
          # found again by responsibility, person and scope, and the start nearest the scenario's day: the days are relative,
          # so a run on a later day must find yesterday's row and not make another
          existing = closest(::GkPeopleAssignment.where(responsibility_id: resp.id, person_id: person.id, scope_type: type, scope_id: sid), :valid_from, from)
          next ctx.note(:assignment, i, existing, false) if existing

          by = a['by'] ? ctx.get(:user, a['by']) : nil
          row = ::GkPeopleAssignment.new(responsibility: resp, person: person, scope_type: type, scope_id: sid, valid_from: from,
                                       valid_to: (a.key?('to') ? ctx.day(a['to']) : nil), created_by_id: by&.id,
                                       deputy_person_id: (a['deputy'] ? scenario_person(ctx, a['deputy'])&.id : nil),
                                       deputy_valid_from: (a.key?('deputy_from') ? ctx.day(a['deputy_from']) : nil),
                                       deputy_valid_to: (a.key?('deputy_to') ? ctx.day(a['deputy_to']) : nil))
          row.ended_at = Time.current if row.valid_to && row.valid_to < ::User.current.today
          ctx.as(by || ::User.current) do
            row.save!
            Responsibilities.write(row, 'responsibility_assigned', { valid_from: row.valid_from.to_s, valid_to: row.valid_to.to_s })
          end
          ctx.note(:assignment, i, row, true)
        end
      end

      # Who acts for a responsibility (at: days from today; scope: project or group key): finds a person key, or
      # vacancy: true; via: holder or deputy
      ::GkScenarios::Expect.register('resp_holder') do |ctx, e|
        on = e.key?('at') ? ctx.day(e['at']) : ::User.current.today   # at: days from today (on: would be read by YAML as true)
        r = Responsibilities.holder(e['resp_holder'], resp_scope_check(ctx, e['scope']), on: on)
        if e['vacancy']
          { 'ok' => r[:vacancy] == true, 'want' => 'vacancy', 'got' => r[:person]&.name || 'vacancy' }
        else
          want = scenario_person(ctx, e['finds'])
          via_ok = e['via'].nil? || r[:via].to_s == e['via'].to_s
          { 'ok' => !want.nil? && r[:person]&.id == want.id && via_ok, 'want' => "#{want&.name} (#{e['via'] || 'any'})",
            'got' => "#{r[:person]&.name || 'vacancy'} (#{r[:via]})" }
        end
      end

      # How many hold a responsibility now (an area may have several)
      ::GkScenarios::Expect.register('resp_holders') do |ctx, e|
        got = Responsibilities.holders(e['resp_holders'], resp_scope_check(ctx, e['scope'])).map { |a| a.person.name }.sort
        want = Array(e['persons']).map { |k| scenario_person(ctx, k)&.name }.compact.sort
        { 'ok' => got == want, 'want' => want.join(', '), 'got' => got.join(', ').presence || '-' }
      end

      # A function takes no second holder in the same scope and period
      ::GkScenarios::Expect.register('resp_one_holder') do |ctx, e|
        resp = ::GkPeopleResponsibility.find_by(key: e['resp_one_holder'])
        person = scenario_person(ctx, e['person'])
        a = ::GkPeopleAssignment.new(responsibility: resp, person: person, scope_type: 'organization', valid_from: ::User.current.today)
        ok = resp && person && !a.valid?
        { 'ok' => ok, 'want' => 'refused', 'got' => ok ? 'refused' : 'accepted' }
      end
    end
  end
end

module GkPeople
  module Scenarios
    # credentials in scenarios (people.credential_kinds and people.credentials): the kinds (names in the locale,
    # people.credential_kinds.<key>), and who holds which credential, issued (days from today) and valid until (to:, or
    # the kind's months), the issuer and a revocation's reason in the locale (people.credentials.<key>). Found again by
    # holder, kind and issue day. Expectations: a credential's status, whether a holder has one in force, who sees it,
    # and what a person lacks for a responsibility.
    # A relation and a consent of the scenario, found by what it says (the check has no notes of the create)
    def self.scenario_relation(ctx, key)
      r = Array((ctx.scenario.data['people'] || {})['relations']).detect { |x| x['key'] == key.to_s }
      org = r && scenario_org(ctx, r['org'])
      kind = r && ::GkPeopleOrgKind.find_by(key: r['kind'].to_s)
      return nil unless org && kind

      pr = r['project'] && ctx.scenario.list(:projects).detect { |x| x['key'] == r['project'] }
      project = pr && ::Project.find_by(identifier: pr['identifier'])
      ::GkPeopleOrganizationKind.where(organization_id: org.id, kind_id: kind.id, project_id: project&.id).order(:id).last
    end

    # A sha256 the scenario writes itself is checked as the import checks any manifest (a wrong one stops the step). nil
    # without a manifest.
    def self.import_manifest(ctx, im, bytes, filename)
      m = im['manifest']
      return nil unless m.is_a?(Hash)

      m = m.to_h { |k, v| [k.to_s, v] }
      entry = m['files'].is_a?(Array) ? m['files'].first : m['files']
      entry = entry.is_a?(Hash) ? entry.to_h { |k, v| [k.to_s, v] } : {}
      raw = bytes.to_s.b
      entry['file'] ||= filename
      entry['source'] ||= ctx.scenario.t(:people, :imports, im['key'], :source)
      entry['source_time'] ||= (ctx.day(im['source_on']).in_time_zone + 6.hours).iso8601 if im['source_on']
      entry['retrieved'] ||= Time.current.iso8601
      entry['rows'] ||= [raw.dup.force_encoding('UTF-8').scrub.lines.count { |l| l.strip != '' } - 1, 0].max
      entry['size'] ||= raw.bytesize
      entry['sha256'] ||= Digest::SHA256.hexdigest(raw)
      m.merge('files' => [entry])
    end

    # One relation of people.relations on the organization (the steps people_relations and people_relations_imported):
    # found by organization, kind and project, made as the person named when it is not there (or when the scenario ends it
    # and the one there is open)
    def self.relation!(ctx, r, org)
      s = ctx.scenario
      kind = ::GkPeopleOrgKind.find_by!(key: r['kind'].to_s)
      project = r['project'] ? ctx.get(:project, r['project']) : nil
      rel = ::GkPeopleOrganizationKind.where(organization_id: org.id, kind_id: kind.id, project_id: project&.id).order(:id).last
      created = rel.nil? || (r['to'] && rel.valid_to.nil?)
      if created
        by = ctx.get(:user, r['by'])
        ctx.as(by) do
          rel = ::GkPeopleOrganizationKind.create!(organization_id: org.id, kind_id: kind.id, project_id: project&.id,
                                                 valid_from: r['from'] ? ctx.day(r['from']) : nil, valid_to: r['to'] ? ctx.day(r['to']) : nil,
                                                 reason: s.t?(:people, :relations, r['key'], :reason), created_at: Time.current, created_by_id: by.id)
          GkPeople.write_on(org, 'organization_relation_added', { kind: kind.key, project: project&.identifier }.compact, reason: rel.reason)
        end
      end
      ctx.note(:org_relation, r['key'], rel, created)
    end

    def self.scenario_consent(ctx, key)
      c = Array((ctx.scenario.data['people'] || {})['consents']).detect { |x| x['key'] == key.to_s }
      person = c && scenario_person(ctx, c['person'])
      person && ::GkPeopleConsent.where(person_id: person.id, purpose: ctx.scenario.t(:people, :consents, key, :purpose)).order(:id).last
    end

    def self.scenario_org(ctx, key)
      ::GkPeopleOrganization.find_by(name: ctx.scenario.t(:people, :organizations, key, :name))
    end

    def self.scenario_credential_row(ctx, key)
      Array((ctx.scenario.data['people'] || {})['credentials']).detect { |c| c['key'] == key.to_s }
    end

    def self.scenario_holder(ctx, row)
      row['organization'] ? scenario_org(ctx, row['organization']) : scenario_person(ctx, row['person'])
    end

    def self.scenario_credential(ctx, key)
      row = scenario_credential_row(ctx, key)
      holder = row && scenario_holder(ctx, row)
      return nil unless holder

      closest(::GkPeopleCredential.where(Credentials.column_for(holder) => holder.id, credential_key: row['kind']), :issued_on,
              row.key?('issued') ? ctx.day(row['issued']) : nil)
    end

    # The row whose date is nearest the scenario's day (relative days move with the calendar), within 60 days; the
    # oldest when several are equally near, so a scenario's own row wins over a later one made by hand
    def self.closest(scope, column, day)
      rows = scope.order(:id).to_a
      return rows.detect { |r| r[column].nil? } if day.nil?

      near = rows.select { |r| r[column] && (r[column] - day).abs <= 60 }
      near.min_by { |r| [(r[column] - day).abs, r.id] }
    end

    def self.register_credential_scenarios!
      ::GkScenarios::Steps.register('people_credentials', plugin: :gk_people, order: 172) do |ctx|
        next unless Credentials.ready?

        data = ctx.scenario.data['people'] || {}
        Array(data['credential_kinds']).each_with_index do |k, i|
          row = ::GkPeopleCredentialKind.find_by(key: k['key'])
          made = row.nil?
          row ||= ::GkPeopleCredentialKind.create!(key: k['key'], name: ctx.scenario.t(:people, :credential_kinds, k['key'], :name),
                                                 description: ctx.scenario.t?(:people, :credential_kinds, k['key'], :description),
                                                 applies_to: k['applies_to'] || 'person', renew_months: k['renew_months'], position: (i + 1) * 10)
          ctx.note(:credential_kind, k['key'], row, made)
        end
        Array(data['credentials']).each do |c|
          holder = scenario_holder(ctx, c)
          next unless holder

          existing = scenario_credential(ctx, c['key'])
          next ctx.note(:credential, c['key'], existing, false) if existing

          by = c['by'] ? ctx.get(:user, c['by']) : nil
          row = ::GkPeopleCredential.new(credential_key: c['kind'], issued_on: (c.key?('issued') ? ctx.day(c['issued']) : nil),
                                       valid_to: (c.key?('to') ? ctx.day(c['to']) : nil), reference: c['reference'],
                                       issuer: ctx.scenario.t?(:people, :credentials, c['key'], :issuer), created_by_id: by&.id)
          row.person = holder if holder.is_a?(::GkPeoplePerson)
          row.organization = holder if holder.is_a?(::GkPeopleOrganization)
          ctx.as(by || ::User.current) do
            row.save!
            Credentials.write(row, 'credential_added', { issued_on: row.issued_on.to_s, valid_to: row.valid_to.to_s, issuer: row.issuer })
            Credentials.revoke!(row, reason: ctx.scenario.t(:people, :credentials, c['key'], :revoke_reason), by: by) if c['revoked']
          end
          ctx.note(:credential, c['key'], row, true)
        end
      end

      # A credential's status today: valid, expiring, not_yet, expired or revoked
      ::GkScenarios::Expect.register('cred_status') do |ctx, e|
        c = scenario_credential(ctx, e['cred_status'])
        got = c ? c.status.to_s : 'missing'
        { 'ok' => got == e['is'].to_s, 'want' => e['is'].to_s, 'got' => got }
      end

      # A person or an organization holds a credential of the kind in force today (equals: false for not)
      ::GkScenarios::Expect.register('cred_valid') do |ctx, e|
        holder = e['organization'] ? scenario_org(ctx, e['organization']) : scenario_person(ctx, e['person'])
        got = holder ? Credentials.valid?(holder, e['cred_valid']) : false
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => !holder.nil? && got == want, 'want' => want.to_s, 'got' => holder ? got.to_s : 'no holder' }
      end

      # Who sees a credential (an expired one of a person: herself and handlers only)
      ::GkScenarios::Expect.register('cred_sees') do |ctx, e|
        c = scenario_credential(ctx, e['cred_sees'])
        user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['user']))
        got = c && user ? Credentials.visible?(c, user) : false
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => !c.nil? && !user.nil? && got == want, 'want' => want.to_s, 'got' => c ? got.to_s : 'no credential' }
      end

      # What a person lacks for a responsibility's requirements (lacks: [] for nothing)
      ::GkScenarios::Expect.register('resp_lacking') do |ctx, e|
        resp = ::GkPeopleResponsibility.find_by(key: e['resp_lacking'])
        person = scenario_person(ctx, e['person'])
        got = resp && person ? Credentials.lacking(person, resp).sort : nil
        want = Array(e['lacks']).map(&:to_s).sort
        { 'ok' => got == want, 'want' => want.join(', ').presence || '-', 'got' => got.nil? ? 'missing' : (got.join(', ').presence || '-') }
      end
    end
  end
end

module GkPeople
  module Scenarios
    # role_sync in scenarios (people.role_sync): the setting on, the rules (their responsibilities switched on), a sync,
    # then what happens over time: an assignment ended (its role goes) and a role removed by hand (a deviation that is
    # not put back), each followed by a sync. Expectations: who has which role in which project, whose grants a
    # responsibility has, a revoked grant's reason, and a deviation.
    def self.rs_project(ctx, key)
      p = ctx.scenario.list(:projects).detect { |x| x['key'] == key.to_s }
      p ||= Array(ctx.scenario.data['project_types']).flat_map { |t| Array(t['projects']) }.detect { |x| x['key'] == key.to_s }
      p && ::Project.find_by(identifier: p['identifier'])
    end

    def self.rs_role(ctx, key) = ::Role.find_by(name: ctx.scenario.t(:roles, key))

    def self.rs_user(ctx, key) = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, key))

    def self.register_role_sync_scenarios!
      # A relation whose organization the step people made is made here, as before; one whose organization comes from the
      # sync or an import (not under people.organizations, its name in the locale under people.organizations.<key>.name as
      # the file or the source writes it) waits for the step people_relations_imported, after them
      ::GkScenarios::Steps.register('people_relations', plugin: :gk_people, order: 155) do |ctx|
        s = ctx.scenario
        data = s.data['people'] || {}
        Array(data['relations']).each do |r|
          next unless ctx.made['organization'].key?(r['org'].to_s)

          relation!(ctx, r, ctx.get(:organization, r['org']))
        end
        Array(data['consents']).each do |c|
          person = ctx.get(:person, c['person'])
          purpose = s.t(:people, :consents, c['key'], :purpose)
          row = ::GkPeopleConsent.find_by(person_id: person.id, purpose: purpose)
          created = row.nil?
          if created
            by = ctx.get(:user, c['by'])
            ctx.as(by) do
              row = ::GkPeopleConsent.create!(person_id: person.id, purpose: purpose, project_id: c['project'] ? ctx.get(:project, c['project']).id : nil,
                                            given_on: ctx.day(c['given'] || 0), valid_to: c['valid_to'] ? ctx.day(c['valid_to']) : nil,
                                            recorded_by_id: by.id)
              GkPeople.write_on(person, 'person_consent_given', { purpose: purpose })
              if c['revoked']
                row.update!(revoked_on: ctx.day(c['revoked']), revoke_reason: s.t?(:people, :consents, c['key'], :revoke_reason), revoked_by_id: by.id)
                GkPeople.write_on(person, 'person_consent_revoked', { purpose: purpose }, reason: row.revoke_reason)
              end
            end
          end
          ctx.note(:consent, c['key'], row, created)
        end
      end

      # The relations of organizations that the sync (order 160) or an import (order 165) brought, found by their name
      # in the locale; an organization that is still not there stops the step with its key
      ::GkScenarios::Steps.register('people_relations_imported', plugin: :gk_people, order: 168) do |ctx|
        Array((ctx.scenario.data['people'] || {})['relations']).each do |r|
          next if ctx.made['organization'].key?(r['org'].to_s)

          org = scenario_org(ctx, r['org']) or raise ::GkScenarios::Error, ::I18n.t(:error_gk_scenarios_ref, kind: 'organization', key: r['org'])
          relation!(ctx, r, org)
        end
      end

      # { ppl_relation: <key>, state: current|ended|future, as: <user>, visible: true|false }: the relation's state, and
      # whether a user sees it (on the organization's page and as its kind)
      ::GkScenarios::Expect.register('ppl_relation') do |ctx, e|
        rel = scenario_relation(ctx, e['ppl_relation'])
        next({ 'ok' => false, 'want' => e['ppl_relation'].to_s, 'got' => 'no relation' }) unless rel
        want = {}
        got = {}
        if e.key?('state')
          want['state'] = e['state'].to_s
          got['state'] = rel.state.to_s
        end
        if e.key?('as')
          u = ctx.scenario.list(:users).detect { |x| x['key'] == e['as'].to_s }
          user = u && ::User.find_by(login: u['login'])
          next({ 'ok' => false, 'want' => e['as'].to_s, 'got' => 'no user' }) unless user
          want['visible'] = e.key?('visible') ? e['visible'] : true
          got['visible'] = rel.organization.visible_relations(user).any? { |r| r.id == rel.id }
          want['kind_shown'] = want['visible'] && rel.state == :current
          got['kind_shown'] = rel.organization.visible_kinds(user).any? { |k| k.id == rel.kind_id }
        end
        { 'ok' => got == want, 'want' => want.to_json, 'got' => got.to_json }
      end

      # { ppl_consent: <key>, state: current|revoked|expired|future }
      ::GkScenarios::Expect.register('ppl_consent') do |ctx, e|
        c = scenario_consent(ctx, e['ppl_consent'])
        next({ 'ok' => false, 'want' => e['ppl_consent'].to_s, 'got' => 'no consent' }) unless c
        got = { 'state' => c.reload.state.to_s, 'kept' => ::GkPeopleConsent.exists?(c.id) }
        want = { 'state' => e['state'].to_s, 'kept' => true }
        { 'ok' => got == want, 'want' => want.to_json, 'got' => got.to_json }
      end

      # { ppl_internal_org: <person>, org: <organization>, allowed: true|false }: whether one of our own may be tied to it
      ::GkScenarios::Expect.register('ppl_internal_org') do |ctx, e|
        person = scenario_person(ctx, e['ppl_internal_org'])
        person.organization_id = scenario_org(ctx, e['org']).id
        got = person.valid?
        { 'ok' => got == (e.key?('allowed') ? e['allowed'] : true), 'want' => (e.key?('allowed') ? e['allowed'] : true).to_s, 'got' => got.to_s }
      end

      ::GkScenarios::Steps.register('people_role_sync', plugin: :gk_people, order: 495) do |ctx|
        next unless RoleSync.ready?

        data = (ctx.scenario.data['people'] || {})['role_sync'] || {}
        next if data.empty?

        # the scenario's own answer, not the setting through core's cache (another thread may refill it with the value
        # from before this step's uncommitted change)
        on = data['enabled'] ? true : nil
        if data['enabled']
          stored = stored_settings
          Setting.plugin_gk_people = stored.merge('role_sync_enabled' => '1') unless stored['role_sync_enabled'].to_s == '1'
        end
        Array(data['rules']).each_with_index do |r, i|
          resp = ::GkPeopleResponsibility.find_by(key: r['responsibility'])
          role = rs_role(ctx, r['role'])
          next unless resp && role

          resp.update!(role_sync: true) unless resp.role_sync
          target = r['project'] ? 'project' : (r['project_type'] ? 'project_type' : 'scope')
          project = r['project'] ? rs_project(ctx, r['project']) : nil
          type = r['project_type'] && defined?(::GkProjectTypesType) ? ::GkProjectTypesType.find_by(key: r['project_type']) : nil
          row = ::GkPeopleRoleRule.find_by(responsibility_id: resp.id, role_id: role.id, target: target, project_id: project&.id, project_type_id: type&.id)
          made = row.nil?
          row ||= ::GkPeopleRoleRule.create!(responsibility: resp, role: role, target: target, project: project, project_type_id: type&.id,
                                           created_by_id: (r['by'] ? ctx.get(:user, r['by']).id : nil))
          ctx.note(:role_rule, i, row, made)
        end
        # When the sync does not run anyway, the step's report says why
        unless RoleSync.run!(kind: 'scenario', enabled: on)
          cached = (::Setting.plugin_gk_people || {})['role_sync_enabled'].inspect
          stored = (stored_settings['role_sync_enabled']).inspect
          ctx.remark("role_sync did not run: ready=#{RoleSync.ready?} enabled=#{RoleSync.enabled?} running=#{RoleSync.running?} " \
                     "cached=#{cached} stored=#{stored} open_transactions=#{::ActiveRecord::Base.connection.open_transactions}")
        end
        Array(data['end']).each do |e|
          resp = ::GkPeopleResponsibility.find_by(key: e['responsibility'])
          person = scenario_person(ctx, e['person'])
          a = resp && person ? ::GkPeopleAssignment.in_force.find_by(responsibility_id: resp.id, person_id: person.id) : nil
          Responsibilities.end!(a, by: (e['by'] ? ctx.get(:user, e['by']) : nil)) if a
        end
        RoleSync.run!(kind: 'scenario', enabled: on)
        Array(data['by_hand']).each do |h|
          user = rs_user(ctx, h['user'])
          project = rs_project(ctx, h['project'])
          role = rs_role(ctx, h['role'])
          g = user && project && role ? ::GkPeopleRoleGrant.active.find_by(user_id: user.id, project_id: project.id, role_id: role.id, removed_by_hand_at: nil) : nil
          mr = g&.member_role_id && ::MemberRole.find_by(id: g.member_role_id)
          ctx.as(h['by'] ? ctx.get(:user, h['by']) : ::User.current) { mr.destroy } if mr
        end
        RoleSync.run!(kind: 'scenario', enabled: on)
      end

      # A user has a role in a project, by any way (equals: false for not)
      ::GkScenarios::Expect.register('role_has') do |ctx, e|
        user = rs_user(ctx, e['role_has'])
        project = rs_project(ctx, e['project'])
        role = rs_role(ctx, e['role'])
        got = user && project && role ? !RoleSync.member_role_for(user.id, project.id, role.id).nil? : false
        want = e.key?('equals') ? e['equals'] : true
        { 'ok' => !(user && project && role).nil? && got == want, 'want' => want.to_s, 'got' => (user && project && role) ? got.to_s : 'missing' }
      end

      # Whose roles a responsibility gives now
      ::GkScenarios::Expect.register('rs_grants') do |ctx, e|
        resp = ::GkPeopleResponsibility.find_by(key: e['rs_grants'])
        got = resp ? ::GkPeopleRoleGrant.active.joins(:rule).where(gk_people_role_rules: { responsibility_id: resp.id }).includes(:person).map { |g| g.person&.name }.compact.uniq.sort : []
        want = Array(e['persons']).map { |k| scenario_person(ctx, k)&.name }.compact.sort
        { 'ok' => got == want, 'want' => want.join(', '), 'got' => got.join(', ').presence || '-' }
      end

      # A grant of a responsibility to a person was revoked, with the reason
      ::GkScenarios::Expect.register('rs_revoked') do |ctx, e|
        resp = ::GkPeopleResponsibility.find_by(key: e['rs_revoked'])
        person = scenario_person(ctx, e['person'])
        g = resp && person ? ::GkPeopleRoleGrant.where(person_id: person.id).where.not(revoked_at: nil).joins(:rule).where(gk_people_role_rules: { responsibility_id: resp.id }).order(:revoked_at).last : nil
        { 'ok' => g&.revoke_reason == e['reason'].to_s, 'want' => e['reason'].to_s, 'got' => g ? g.revoke_reason.to_s : 'none' }
      end

      # A role a responsibility gave was removed by hand: a deviation, with who
      ::GkScenarios::Expect.register('rs_deviation') do |ctx, e|
        user = rs_user(ctx, e['rs_deviation'])
        project = rs_project(ctx, e['project'])
        role = rs_role(ctx, e['role'])
        g = user && project && role ? ::GkPeopleRoleGrant.deviating.find_by(user_id: user.id, project_id: project.id, role_id: role.id) : nil
        by = e['by'] ? rs_user(ctx, e['by']) : nil
        ok = !g.nil? && (by.nil? || g.removed_by_id == by.id)
        { 'ok' => ok, 'want' => "deviation#{by ? " by #{by.login}" : ''}", 'got' => g ? "deviation by #{g.removed_by&.login || '-'}" : 'none' }
      end
    end
  end
end

module GkPeople
  module Scenarios
    # Where an import's facts came from, for the expectations org_is and person_by_email (from:): info_source when
    # written there (by hand or by the file's own column, or by an import without records), otherwise the source of
    # a reading that set one of the record's fields; nil when neither
    def self.facts_from(rec, label)
      return nil unless rec
      return rec.info_source if rec.info_source == label || !Import.readings?

      key = rec.is_a?(::GkPeopleOrganization) ? 'organization' : 'person'
      hit = ::GkRecordsFieldOrigin.joins(:reading).where(target_type: key, target_id: rec.id, gk_records_readings: { source_label: label }).exists?
      hit ? label : rec.info_source
    end

    # A made-up file in SCB's form of workplaces (Scb.ps1's columns; semicolon, UTF-8 with a byte order mark, a decimal
    # point) and its made-up manifest: two workplaces of one company (556000-0201, a number no scenario uses) and a sole
    # trader with a masked number. Telephone, e-mail and a block are filled so that the expectation sees them left out.
    SCB_PROBE_LABEL = 'SCB AFR (scenariots prov)'
    SCB_PROBE_FILE = 'arbetsstallen_2283_20261005.csv'

    def self.scb_probe_bytes
      cols = %w[kommun_kod kommun cfarNr orgNr benamning sni_kod sni_text sni_avdelning ovriga_sni storleksklass_kod storleksklass
                status_kod status typ besoksadress besok_postnr besok_postort postadress co_adress post_postnr post_postort telefon epost
                startdatum slutdatum tatort sweref_n sweref_e sweref_n_adress sweref_e_adress reklamsparr telefonsparr epostsparr]
      rows = [
        { 'cfarNr' => '90000001', 'orgNr' => '5560000201', 'benamning' => 'Provverkstaden Bräcke', 'sni_kod' => '25620', 'besoksadress' => 'Provgatan 1',
          'besok_postort' => 'Bräcke', 'sweref_n' => '6955123.500', 'sweref_e' => '512345.250', 'telefon' => '0600-000001', 'epost' => 'a@prov.example',
          'reklamsparr' => 'Reklamspärr' },
        { 'cfarNr' => '90000002', 'orgNr' => '5560000201', 'benamning' => 'Provverkstaden Gällö', 'sni_kod' => '25620', 'besoksadress' => 'Provvägen 2',
          'besok_postort' => 'Gällö', 'sweref_n' => '6960001.000', 'sweref_e' => '500002.000' },
        { 'cfarNr' => '90000003', 'orgNr' => '19650101XXXX', 'benamning' => 'Provfirman Snickeri', 'sni_kod' => '16230', 'besoksadress' => 'Provstigen 3',
          'besok_postort' => 'Bräcke', 'telefon' => '0600-000003' }
      ]
      common = { 'kommun_kod' => '2283', 'kommun' => 'Bräcke', 'status' => 'Verksam' }
      lines = [cols.join(';')] + rows.map { |r| cols.map { |c| common.merge(r)[c].to_s }.join(';') }
      "\xEF\xBB\xBF".b + lines.join("\r\n").b + "\r\n".b
    end

    # The made-up manifest in the keys records reads, with what a script adds about its computer and its errors and a
    # path in the file's name, so the reading shows those are not kept
    def self.scb_probe_manifest(bytes, sha256: nil)
      { 'script' => 'Scb.ps1', 'revision' => '0.00.002', 'result' => 'ok', 'computer' => 'PROVDATOR', 'errors' => ['påhittat fel'],
        'retrieved' => '2026-10-06T07:00:00+02:00',
        'files' => [{ 'file' => "C:/prov/ut/#{SCB_PROBE_FILE}", 'kind' => 'arbetsställen', 'source' => SCB_PROBE_LABEL,
                      'url' => 'https://example.invalid/arbetsstallen/kommun/2283?nyckel=prov',
                      'format' => 'CSV; semikolon; UTF-8 med BOM; punkt som decimaltecken; koordinater SWEREF 99 TM (EPSG:3006)',
                      'source_ref' => 'kommun 2283', 'source_time' => '2026-10-05T06:00:00+02:00', 'rows' => 3, 'size' => bytes.bytesize,
                      'sha256' => sha256 || Digest::SHA256.hexdigest(bytes) }] }
    end

    def self.scenario_result(checks)
      failed = checks.reject { |_k, ok| ok }.map(&:first)
      { 'ok' => failed.empty?, 'want' => checks.map(&:first).join(', '), 'got' => failed.empty? ? 'ok' : "not: #{failed.join(', ')}" }
    end

    def self.register_reading_scenarios!
      # ppl_scb_reading: <part>: the made-up SCB file read through the import as the scenario's user in by (or the first
      # active administrator), in a transaction that is rolled back.
      ::GkScenarios::Expect.register('ppl_scb_reading') do |ctx, e|
        part = e['ppl_scb_reading'].to_s
        parts = %w[reading refused origin again hierarchy cycle]
        next({ 'ok' => false, 'want' => parts.join(' | '), 'got' => part }) unless parts.include?(part)
        next({ 'ok' => false, 'want' => 'records with readings', 'got' => 'none' }) unless Import.readings?

        actor = e['by'] ? ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['by'])) : ::User.active.where(admin: true).order(:id).first
        next({ 'ok' => false, 'want' => 'a user', 'got' => '-' }) unless actor

        bytes = scb_probe_bytes
        sum = Digest::SHA256.hexdigest(bytes)
        api = ::GkRecords::Readings
        ids = %w[90000001 90000002 90000003]
        result = nil
        begin
          ::GkPeopleOrganization.transaction(requires_new: true) do
            checks = []
            ctx.as(actor) do
              if part == 'refused'
                before = [::GkPeopleImport.count, ::GkRecordsReading.count]
                refused = begin
                  Import.start!(resource: 'organizations', bytes: bytes, source_label: '', filename: SCB_PROBE_FILE, user: actor,
                                manifest: scb_probe_manifest(bytes, sha256: 'f' * 64))
                  false
                rescue ArgumentError => ex
                  ex.message.include?('SHA-256')
                end
                checks << ['refused with the checksum', refused]
                checks << ['nothing made', [::GkPeopleImport.count, ::GkRecordsReading.count] == before]
              else
                orgs_before = ::GkPeopleOrganization.count
                imp = Import.start!(resource: 'organizations', bytes: bytes, source_label: '', filename: SCB_PROBE_FILE, user: actor,
                                    manifest: scb_probe_manifest(bytes))
                Import.run!(imp, user: actor)
                imp.reload
                rd = imp.reading
                wp = ids.map { |id| api.find_by_source_id('organization', SCB_PROBE_LABEL, id) }
                case part
                when 'reading'
                  checks << ['profile scb', imp.profile == Import::SCB_PROFILE]
                  checks << ['source from manifest.json', rd && rd.source_label == SCB_PROBE_LABEL && imp.source_label == SCB_PROBE_LABEL]
                  checks << ['source time', rd && rd.source_time&.to_date == Date.new(2026, 10, 5)]
                  checks << ['route file, format CSV', rd && rd.route == 'file' && rd.format == 'CSV' && rd.source_ref == 'kommun 2283']
                  checks << ['three posts', rd && rd.rows == 3 && rd.counts['added'] == 3]
                  checks << ['files', rd && rd.files == [{ 'file' => SCB_PROBE_FILE, 'size' => bytes.bytesize, 'sha256' => sum }]]
                  checks << ['no file kept', ::Attachment.where(container_type: 'GkRecordsReading').none? && !imp.has_attribute?(:raw_file) &&
                                             imp.raw_rows.empty?]
                  trimmed = [rd&.manifest, imp.manifest].all? do |m|
                    m.is_a?(Hash) && !m.key?('computer') && !m.key?('errors') &&
                      m['files'].all? { |f| f['file'] == SCB_PROBE_FILE && !f['url'].to_s.include?('?') }
                  end
                  checks << ['manifest trimmed', trimmed]
                  checks << ['retrieved and mapping', rd && rd.retrieved_at == Time.zone.parse('2026-10-06T07:00:00+02:00') && rd.mapping == 'scb_workplaces@1']
                when 'origin'
                  o = wp[0] && api.origin(wp[0], 'name')
                  label = rd ? api.label(rd) : ''
                  checks << ['pointer', o && o[:reading]&.id == rd&.id && o[:source_id] == '90000001']
                  checks << ['value digest, not the value', o && o[:value_sha256] == api.value_digest(wp[0].name) && o[:value_sha256] != wp[0].name &&
                                                            o[:source].nil?]
                  checks << ['unchanged', wp[0] && api.unchanged?(wp[0], 'name')]
                  checks << ['label', label.start_with?("#{SCB_PROBE_LABEL} · CSV · ") && label.include?('2026-10-05')]
                  html = begin
                    ::GkPeopleOrganizationsController.renderer.render(inline: '<%= gk_people_source_note(o, :name) %>', locals: { o: wp[0] })
                  rescue StandardError => ex
                    "error #{ex.class}"
                  end
                  checks << ['shown with a link', rd && html.include?(ERB::Util.h(label)) && html.include?("/gk_records/readings/#{rd.id}")]
                when 'again'
                  imp2 = Import.start!(resource: 'organizations', bytes: bytes, source_label: '', filename: SCB_PROBE_FILE, user: actor,
                                       manifest: scb_probe_manifest(bytes))
                  Import.run!(imp2, user: actor)
                  imp2.reload
                  rd2 = imp2.reading
                  again = ids.map { |id| api.find_by_source_id('organization', SCB_PROBE_LABEL, id) }
                  checks << ['a second reading', rd2 && rd && rd2.id != rd.id]
                  checks << ['nothing new', imp2.counts['new'].to_i.zero? && imp2.counts['unchanged'].to_i == 3]
                  checks << ['the same workplaces', wp.compact.size == 3 && again.map { |x| x&.id } == wp.map(&:id)]
                  checks << ['pointer moved', rd2 && api.origin(wp[0], 'source_id')&.dig(:reading)&.id == rd2.id]
                  checks << ['first reading stays', rd && ::GkRecordsReading.exists?(rd.id)]
                  checks << ['no organization added', ::GkPeopleOrganization.count == orgs_before + 4]
                when 'hierarchy'
                  a, b, c = wp
                  company = a&.parent
                  checks << ['one company', company && b && b.parent_id == company.id && ::GkPeopleOrganization.count == orgs_before + 4]
                  checks << ['the company has the number', company && company.org_no == '556000-0201' && company.name == 'Provverkstaden Bräcke']
                  checks << ['the workplaces have none', a && b && a.org_no.nil? && b.org_no.nil?]
                  checks << ['sole trader alone', c && c.parent_id.nil? && c.org_no.nil?]
                  checks << ['coordinates', a && a.location_n == BigDecimal('6955123.5') && a.location_e == BigDecimal('512345.25') && a.location_crs == 'EPSG:3006']
                  checks << ['no telephone or e-mail', a && c && a.phone.nil? && a.email.nil? && c.phone.nil?]
                  checks << ['company made by the reading', company && api.origin(company, 'org_no')&.dig(:reading)&.id == rd&.id]
                when 'cycle'
                  company = wp[0]&.parent
                  if company
                    company.parent_id = wp[0].id
                    under_child = !company.valid? && company.errors.full_messages.include?(I18n.t(:error_gk_people_org_parent_cycle))
                    company.parent_id = company.id
                    under_self = !company.valid?
                    checks << ['not under its own workplace', under_child]
                    checks << ['not under itself', under_self]
                  else
                    checks << ['a company', false]
                  end
                end
              end
            end
            result = scenario_result(checks)
            raise ::ActiveRecord::Rollback
          end
        rescue StandardError => ex
          result ||= { 'ok' => false, 'want' => part, 'got' => "#{ex.class}: #{ex.message}"[0, 300] }
        end
        result || { 'ok' => false, 'want' => part, 'got' => '-' }
      end

      # ppl_reading_backfill: true: an import run before readings existed (made here as such a row, with an organization
      # it made) gets one reading in hindsight: route file, mode once, no files, "i efterhand" in its label, the fields
      # the import set pointing to it, info_source untouched, and never a second one. In a transaction that is rolled
      # back.
      ::GkScenarios::Expect.register('ppl_reading_backfill') do |_ctx, _e|
        next({ 'ok' => false, 'want' => 'records with readings', 'got' => 'none' }) unless Import.readings?

        result = nil
        begin
          ::GkPeopleOrganization.transaction(requires_new: true) do
            label = 'Gammal import (scenariots prov)'
            at = 30.days.ago
            org = ::GkPeopleOrganization.create!(name: 'Efterhand Prov AB', org_no: '556000-0299', city: 'Bräcke', info_source: label,
                                               info_source_on: ::User.current.today - 40)
            imp = ::GkPeopleImport.create!(resource: 'organizations', source_label: label, source_on: ::User.current.today - 40, mode: 'fill', state: 'done',
                                         created_at: at, finished_at: at, counts_json: { 'new' => 1 }.to_json,
                                         rows_json: { 'preview' => [{ 'line' => 2, 'action' => 'new', 'target_id' => org.id,
                                                                      'changes' => { 'name' => [nil, org.name], 'city' => [nil, 'Bräcke'] },
                                                                      'errors' => [], 'warnings' => [] }] }.to_json)
            rd = ReadingBackfill.for_import(imp)
            again = ReadingBackfill.for_import(imp.reload)
            api = ::GkRecords::Readings
            checks = []
            checks << ['a reading', !rd.nil?]
            checks << ['in hindsight', rd && rd.made_afterwards && rd.route == 'file' && rd.mode == 'once' && rd.files.empty?]
            checks << ['no value digest', ::GkRecordsFieldOrigin.where(reading_id: rd&.id).pluck(:value_sha256).compact.empty?]
            checks << ['label', rd && api.label(rd).include?(I18n.t(:label_gk_records_reading_afterwards))]
            checks << ['source and time', rd && rd.source_label == label && rd.source_time&.to_date == ::User.current.today - 40]
            checks << ['fields point to it', rd && api.origin(org, 'city')&.dig(:reading)&.id == rd.id && api.origin(org, 'name')&.dig(:reading)&.id == rd.id]
            checks << ['info_source kept', org.reload.info_source == label]
            checks << ['the import knows it', rd && imp.reload.reading_id == rd.id]
            checks << ['never twice', again.nil?]
            result = scenario_result(checks)
            raise ::ActiveRecord::Rollback
          end
        rescue StandardError => ex
          result ||= { 'ok' => false, 'want' => 'backfill', 'got' => "#{ex.class}: #{ex.message}"[0, 300] }
        end
        result || { 'ok' => false, 'want' => 'backfill', 'got' => '-' }
      end
    end
  end
end

module GkPeople
  module Scenarios
    # Snabbkontakter in the scenario. One expectation with a part, each run on a meeting made for it in the project named
    # (the meeting package's tracker), as the user named, in a transaction that is rolled back: { ppl_quick: <part>,
    # meeting: improvement, as: olle } (person: and org: name the scenario's own).
    QUICK_PARTS = %w[parse meeting unverified partly olle raise merge different twenty paste move scb switch hidden].freeze

    def self.register_quick_scenarios!
      # people_quick: quick contact lines saved on a meeting of the scenario as data that stays, through the box
      # Deltagare's own save (Quick.save_line! with the meeting as context) as the person named.
      # people.quick: { key, meeting: (an issue key, of the meeting package's tracker), by: }; the lines are text in the
      # locale (people.quick.<key>.lines: a list, or one text with a line per contact), since they hold names. After the
      # issues and records' links (order 360). A line is saved once: a person or an organization linked from the meeting
      # whose created event has the line as written is that line, found again. The function people.quick is switched on
      # when it is off. A line refused (empty, or a field too long) stops the step with its message.
      ::GkScenarios::Steps.register('people_quick', plugin: :gk_people, order: 360) do |ctx|
        rows = Array((ctx.scenario.data['people'] || {})['quick'])
        next if rows.empty?
        raise ::GkScenarios::Error, 'people quick: quick contacts (migration 020) and records' unless Quick.ready? && GkPeople.records?

        scenario_feature!(Quick::FEATURE)
        rows.each do |q|
          by = ctx.get(:user, q['by'])
          issue = ctx.get(:issue, q['meeting'])
          text = ctx.scenario.t?(:people, :quick, q['key'], :lines)
          lines = text.is_a?(Array) ? text.map { |l| l.to_s.strip }.reject(&:empty?) : QuickParse.lines(text)
          raise ::GkScenarios::Error, ::I18n.t(:error_gk_scenarios_text, path: "people.quick.#{q['key']}.lines", lang: ctx.scenario.locale) if lines.empty?

          ctx.as(by) do
            qc = Quick.context("issue:#{issue.id}", by) or raise ::GkScenarios::Error, "people quick #{q['key']}: #{by.login} may not save on #{issue.id}"
            lines.each_with_index do |line, i|
              done = ::GkRecordsLink.active.where(source_type: 'issue', source_id: issue.id, kind: [Quick::PARTICIPANT, Quick::MEETING_ORG])
                                 .to_a.filter_map { |l| Quick.find(l.target_type, l.target_id) }.detect { |rec| Quick.original_text(rec) == line }
              next ctx.note(:people_quick, "#{q['key']}.#{i + 1}", done, false) if done

              res = Quick.save_line!(line, qc, user: by)
              raise ::GkScenarios::Error, "people quick #{q['key']}.#{i + 1}: #{res.errors.join(', ')}" unless res.ok

              ctx.note(:people_quick, "#{q['key']}.#{i + 1}", res.person || res.organization, !res.person.nil? || res.org_made == true)
            end
          end
        end
      end

      # { ppl_quick_line: <people.quick key>, line: n (from 1), organization: <key>, quick: true|false, unverified: true }
      # the post that line of the step people_quick made on its meeting is there, linked from the meeting, with the line
      # as written in its created event; only what is given besides is compared (the person's organization by the
      # scenario's key, whether the post is still quick, and records' verification status unverified)
      ::GkScenarios::Expect.register('ppl_quick_line') do |ctx, e|
        q = Array((ctx.scenario.data['people'] || {})['quick']).detect { |x| x['key'] == e['ppl_quick_line'].to_s }
        issue = q && ::GkScenarios::Expect.issue_for(ctx, q['meeting'])
        text = q && ctx.scenario.t?(:people, :quick, q['key'], :lines)
        lines = text.is_a?(Array) ? text.map { |l| l.to_s.strip }.reject(&:empty?) : QuickParse.lines(text)
        line = lines[(e['line'] || 1).to_i - 1]
        next({ 'ok' => false, 'want' => "#{e['ppl_quick_line']} line #{e['line'] || 1}", 'got' => 'no meeting or line' }) unless issue && line && GkPeople.records?

        rec = ::GkRecordsLink.active.where(source_type: 'issue', source_id: issue.id, kind: [Quick::PARTICIPANT, Quick::MEETING_ORG]).order(:id)
                          .to_a.filter_map { |l| Quick.find(l.target_type, l.target_id) }.detect { |r| Quick.original_text(r) == line }
        want = { 'line' => line }
        got = { 'line' => rec ? Quick.original_text(rec) : nil }
        if e.key?('organization')
          want['organization'] = ctx.scenario.t(:people, :organizations, e['organization'], :name)
          got['organization'] = rec.is_a?(::GkPeoplePerson) ? rec.organization&.name : rec&.name
        end
        if e.key?('quick')
          want['quick'] = e['quick'] == true
          got['quick'] = rec ? Quick.quick?(rec) : nil
        end
        if e.key?('unverified') && defined?(::GkRecords::Verification)
          want['unverified'] = e['unverified'] == true
          got['unverified'] = rec ? ::GkRecords::Verification.get(rec) == 'unverified' : nil
        end
        { 'ok' => !rec.nil? && got == want, 'want' => want.to_json, 'got' => rec ? got.to_json : 'not on the meeting' }
      end

      ::GkScenarios::Expect.register('ppl_quick') do |ctx, e|
        part = e['ppl_quick'].to_s
        next({ 'ok' => false, 'want' => QUICK_PARTS.join(' | '), 'got' => part }) unless QUICK_PARTS.include?(part)
        next({ 'ok' => false, 'want' => 'quick contacts (migration 020) and records', 'got' => 'none' }) unless Quick.ready? && Quick.records?
        if part == 'switch' && !(defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register) && ::GkRecords::Features.find(Quick::FEATURE))
          next({ 'ok' => false, 'want' => "records' register with people.quick", 'got' => 'none' })
        end

        user = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['as'] || 'olle'))
        project = ::Project.where(id: ::GkScenarios::Expect.project_id(ctx, e['meeting'] || 'improvement')).first
        tracker = defined?(::GkProjectTypes::Meeting) ? ::GkProjectTypes::Meeting.tracker : nil
        next({ 'ok' => false, 'want' => 'user, project and the meeting tracker', 'got' => '-' }) unless user && project && tracker

        result = nil
        begin
          ::GkPeoplePerson.transaction(requires_new: true) do
            scenario_feature!(Quick::FEATURE) # off for a new installation; rolled back with the rest
            checks = []
            ctx.as(user) do
              issue = ::Issue.new(project: project, tracker: tracker, author: user, subject: 'gk_people scenario quick contacts',
                                  priority: ::IssuePriority.default || ::IssuePriority.active.first)
              issue.save!
              qc = Quick.context("issue:#{issue.id}", user)
              checks << ['may save on the meeting', !qc.nil?]
              links = lambda do |rec, kind|
                ::GkRecordsLink.active.where(source_type: 'issue', source_id: issue.id, kind: kind, target_type: Quick.key_of(rec), target_id: rec.id).exists?
              end
              created = ->(rec) { Quick.created_event(rec)&.details_hash || {} }
              case part
              when 'parse'
                r = Quick.read('Lotta, ekonomi, Företag AB')
                checks << ['name, role, organization', r[:parts].map { |p| p['field'] } == %w[name role organization]]
                v = QuickParse.values(r[:parts])
                checks << ['values', v['name'] == 'Lotta' && v['role'].to_s.casecmp?('ekonomi') && v['organization'] == 'Företag AB']
                r2 = Quick.read('Lotta, lotta@foretag.example, ekonomi, osäkert')
                checks << ['e-mail and unverified', r2[:unverified] && QuickParse.values(r2[:parts])['email'] == 'lotta@foretag.example']
              when 'meeting'
                res = Quick.save_line!('Lotta, ekonomi, Företag AB', qc, user: user)
                p = res.person
                o = res.organization
                checks << ['saved', res.ok && p && o]
                checks << ['quick person', p && p.quick && p.first_name == 'Lotta' && p.title.to_s.casecmp?('ekonomi') && p.created_by_id == user.id]
                checks << ['organization', o && (o.quick || !res.org_made) && p&.organization_id == o.id]
                checks << ['meeting links', p && o && links.call(p, Quick::PARTICIPANT) && links.call(o, Quick::MEETING_ORG)]
                d = p ? created.call(p) : {}
                checks << ['line in the event', d['quick'] == true && d['text'] == 'Lotta, ekonomi, Företag AB' && Array(d['parts']).size == 3]
                checks << ['in Att komplettera', p && Quick.to_complete(user: user, mine: true, project: project).first.exists?(id: p.id)]
                checks << ['counted', Quick.count_mine(user).positive?]
              when 'unverified'
                res = Quick.save_line!('Lotta, lotta@foretag.example, ekonomi, osäkert', qc, user: user)
                p = res.person
                checks << ['saved', res.ok && p]
                checks << ['e-mail', p&.email == 'lotta@foretag.example']
                checks << ['unverified', p && ::GkRecords::Verification.get(p) == 'unverified']
              when 'partly'
                # "?" gives partly verified where the place has it, unverified with the tip where it does not (the
                # levels passed directly, so no setting is changed)
                res = Quick.save_line!('Lotta Berg?, lotta.berg@foretag.example, ekonomi', qc, user: user)
                p = res.person
                checks << ['saved', res.ok && p]
                checks << ['partly verified', p && ::GkRecords::Verification.get(p) == 'partly_verified']
                checks << ['no tip', res.ok && res.tip.nil?]
                off = ->(_place) { %w[none unverified verified] }
                res2 = Quick.save_line!('Lotta Ek?, lotta.ek@foretag.example, ekonomi', qc, user: user, levels: off)
                p2 = res2.person
                checks << ['saved with partly off', res2.ok && p2]
                checks << ['unverified with partly off', p2 && ::GkRecords::Verification.get(p2) == 'unverified']
                checks << ['the tip', res2.ok && res2.tip.to_s.include?(GkPeople::VerificationPlaces.word_or_default('unverified', 'person'))]
                pv = QuickParse.status(Quick.read('Lotta Ek?, ekonomi'), %w[none unverified verified])
                checks << ['the preview falls back', pv == ['unverified', true]]
              when 'olle'
                res = Quick.save_line!('Olle, Trädfällare AB', qc, user: user)
                p = res.person
                o = res.organization
                checks << ['both in one step', res.ok && p && o && p.organization_id == o.id && p.quick]
                checks << ['organization quick or found', o && (o.quick || !res.org_made)]
                checks << ['both on the meeting', p && o && links.call(p, Quick::PARTICIPANT) && links.call(o, Quick::MEETING_ORG)]
              when 'raise'
                p = Quick.save_line!('Provperson Klar, Provbolaget Klar AB', qc, user: user).person
                err = p ? Quick.raise!(p, user: user) : 'no person'
                checks << ['raised', err.nil? && !p.reload.quick]
                checks << ['event', ::GkRecordsEvent.where(target_type: 'person', target_id: p.id, kind: 'quick_raised').exists?]
                checks << ['left Att komplettera', !Quick.to_complete(user: user).first.exists?(id: p.id)]
              when 'merge'
                existing = scenario_person(ctx, e['person'] || 'buyer')
                checks << ['the existing person', existing && existing.first_name.present? && existing.organization]
                if existing&.organization
                  res = Quick.save_line!("#{existing.first_name}, #{existing.organization.name}", qc, user: user)
                  q = res.person
                  checks << ['saved', res.ok && q && q.organization_id == existing.organization_id]
                  checks << ['suggested', q && Quick.suggestions(q).map(&:id).include?(existing.id)]
                  checks << ['not by itself', q && Quick.merged_into(q).nil?]
                  old = q && ::GkRecordsLink.active.find_by(source_type: 'issue', source_id: issue.id, kind: Quick::PARTICIPANT, target_type: 'person', target_id: q.id)
                  err = q ? Quick.merge!(q, existing, user: user) : 'no person'
                  checks << ["merged (#{err})", err.nil?]
                  checks << ['same_as', q && ::GkRecordsLink.active.exists?(kind: Quick::SAME, source_type: 'person', source_id: q.id, target_type: 'person', target_id: existing.id)]
                  checks << ['meeting now to the one that stays', links.call(existing, Quick::PARTICIPANT)]
                  checks << ['old link voided and kept', old && old.reload.voided_at && ::GkRecordsLink.exists?(old.id)]
                  checks << ['kept, out of lists', q && ::GkPeoplePerson.exists?(q.id) && !::GkPeoplePerson.not_merged.exists?(id: q.id) && !Quick.to_complete(user: user).first.exists?(id: q.id)]
                  checks << ['events', q && ::GkRecordsEvent.where(target_type: 'person', target_id: q.id, kind: 'quick_merged').exists? &&
                                        ::GkRecordsEvent.where(target_type: 'person', target_id: existing.id, kind: 'quick_merged_in').exists?]
                end
              when 'different'
                org = e['org'] ? scenario_org(ctx, e['org']) : nil
                org ||= ::GkPeopleOrganization.create!(name: 'Provbolaget Två Lotta AB')
                first = ::GkPeoplePerson.create!(first_name: 'Lotta', last_name: 'Andersson', kind: 'external', organization_id: org.id, created_by_id: user.id)
                res = Quick.save_line!("Lotta Andersson, #{org.name}", qc, user: user)
                q = res.person
                checks << ['saved in the organization', res.ok && q && q.organization_id == org.id]
                checks << ['suggested, not merged', q && Quick.suggestions(q).map(&:id).include?(first.id) && Quick.merged_into(q).nil?]
                err = q ? Quick.mark_different!(q, first, user: user) : 'no person'
                checks << ["marked (#{err})", err.nil? && ::GkRecordsLink.active.exists?(kind: Quick::NOT_SAME, source_type: 'person', source_id: q.id, target_id: first.id)]
                checks << ['not suggested again', !Quick.suggestions(q).map(&:id).include?(first.id) && !Quick.suggestions(first).map(&:id).include?(q.id)]
                checks << ['merge refused', !Quick.merge!(q, first, user: user).nil?]
                checks << ['events on both', ::GkRecordsEvent.where(target_type: 'person', target_id: [q.id, first.id], kind: 'quick_marked_different').count == 2]
              when 'twenty'
                results = (1..20).map { |n| Quick.save_line!("Provperson #{n}, Provföretaget Tjugo AB", qc, user: user) }
                ps = results.map(&:person).compact
                checks << ['twenty saved', results.all?(&:ok) && ps.size == 20 && ps.all?(&:quick)]
                checks << ['one organization', ps.map(&:organization_id).uniq.size == 1 && results.count(&:org_made) == 1]
                checks << ['all on the meeting', ps.all? { |p| links.call(p, Quick::PARTICIPANT) }]
              when 'paste'
                text = (1..20).map { |n| "Klistrad #{n}, Provföretaget Klister AB, #{n.odd? ? 'ekonomi' : 'HR'}" }.join("\r\n")
                results = Quick.save_text!("#{text}\n\n", qc, user: user)
                checks << ['twenty posts', results.size == 20 && results.all?(&:ok) && results.map(&:person).compact.map(&:id).uniq.size == 20]
                checks << ['all on the meeting', results.all? { |r| r.person && links.call(r.person, Quick::PARTICIPANT) }]
              when 'move'
                p = Quick.save_line!('Lotta, Ekonomiavdelningen', qc, user: user).person
                before = p && Quick.parts_of(p)
                checks << ['read as description', before && before[1] && before[1]['field'] == 'description' && p.notes == 'Ekonomiavdelningen']
                err = p ? Quick.move_part!(p, 1, 'role', user: user) : 'no person'
                p&.reload
                checks << ["moved (#{err})", err.nil? && p.title == 'Ekonomiavdelningen' && p.notes.blank?]
                checks << ['parts after', p && Quick.parts_of(p)[1]['field'] == 'role']
                checks << ['event', p && ::GkRecordsEvent.where(target_type: 'person', target_id: p.id, kind: 'quick_part_moved').exists?]
                checks << ['line as written kept', p && Quick.original_text(p) == 'Lotta, Ekonomiavdelningen' && created.call(p)['parts'][1]['field'] == 'description']
              when 'scb'
                res = Quick.save_line!('Provverkstaden AB', qc, user: user)
                q = res.organization
                checks << ['quick organization', res.ok && q && q.quick && res.person.nil?]
                found = if Import.readings?
                          bytes = scb_probe_bytes
                          imp = Import.start!(resource: 'organizations', bytes: bytes, source_label: '', filename: SCB_PROBE_FILE, user: user,
                                              manifest: scb_probe_manifest(bytes))
                          Import.run!(imp, user: user)
                          ::GkRecords::Readings.find_by_source_id('organization', SCB_PROBE_LABEL, '90000001')
                        else
                          ::GkPeopleOrganization.create!(name: 'Provverkstaden Bräcke', info_source: SCB_PROBE_LABEL)
                        end
                checks << ['the reading made one', !found.nil?]
                s = q ? Quick.suggestions(q, limit: 20).map(&:id) : []
                checks << ['suggested', found && s.include?(found.id)]
                checks << ['not merged by itself', q && Quick.merged_into(q).nil?]
              when 'switch'
                feats = ::GkRecords::Features
                checks << ['on', Quick.on? && Quick.meeting_box?(issue, user)]
                feats.set!(Quick::FEATURE, false, reason: 'scenario', user: user)
                before = ::GkPeoplePerson.count
                res = Quick.save_line!('Provperson Av, Provbolaget Av AB', qc, user: user)
                checks << ['off', !Quick.on?]
                checks << ['save refused with the message', !res.ok && res.errors == [Quick.off_error]]
                checks << ['nothing saved', ::GkPeoplePerson.count == before && !::GkPeopleOrganization.exists?(name: 'Provbolaget Av AB')]
                checks << ['box not offered', !Quick.meeting_box?(issue, user)]
                checks << ['nothing counted', Quick.count_mine(user).zero?]
                feats.set!(Quick::FEATURE, true, reason: 'scenario', user: user)
                again = Quick.save_line!('Provperson På, Provbolaget På AB', qc, user: user)
                checks << ['on again: box and save', Quick.on? && Quick.meeting_box?(issue, user) && again.ok && again.person]
              when 'hidden'
                other = ::User.find_by(login: ::GkScenarios::Expect.login(ctx, e['hidden_from'] || 'saga'))
                line = 'Provperson Dold, provperson.dold@foretag.example, Provbolaget Dold AB'
                res = Quick.save_line!(line, qc, user: user)
                p = res.person
                o = res.org_made ? res.organization : nil
                ev = p && Quick.created_event(p)
                checks << ['records with private fields', ev.respond_to?(:hidden_fields)]
                checks << ['hidden_from may not see persons', other && !Access.view?(other)]
                checks << ['user may see persons', Access.view?(user)]
                if ev.respond_to?(:hidden_fields) && other
                  checks << ['kept as written', ev.details_hash['text'] == line && Array(ev.details_hash['parts']).size == 3]
                  checks << ['shown to the user', ev.hidden_fields(user).empty? && ev.changes_text(user).include?(line)]
                  api = ev.as_api_json(other)
                  checks << ['hidden from the other', ev.hidden_fields(other).sort == %w[parts text] && !ev.changes_text(other).include?('Provperson Dold') &&
                                                     api[:details]['text'].nil? && api[:details]['parts'].nil? && api[:details_hidden].to_a.sort == %w[parts text]]
                  oev = o && Quick.created_event(o)
                  checks << ['organization line hidden too', oev.nil? || (oev.hidden_fields(other).include?('text') && oev.hidden_fields(user).empty?)]
                end
              end
            end
            result = scenario_result(checks)
            raise ::ActiveRecord::Rollback
          end
        rescue StandardError => ex
          result ||= { 'ok' => false, 'want' => part, 'got' => "#{ex.class}: #{ex.message}"[0, 300] }
        ensure
          # The switches were rolled back with the rest; records must not keep them in memory
          ::GkRecords::Features.forget! if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
        end
        result || { 'ok' => false, 'want' => part, 'got' => '-' }
      end
    end
  end
end
