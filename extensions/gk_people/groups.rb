# frozen_string_literal: true

module GkPeople
  # A group says what it is: what the group does and what its authority is, written as notes in records on the
  # group (a new text is a new note that corrects the old, nothing is overwritten), and the group's history as
  # records events (created, renamed, member added and removed) with who did it. Started and last changed are
  # read from the group and its records, never typed.
  # The longer, approved text (publishing) and the person register's own groups come later; this is core's Group.
  module Groups
    SECTIONS = %w[group_purpose group_authority].freeze
    EVENTS = %w[group_created group_renamed group_member_added group_member_removed].freeze
    TARGET = 'group'

    module_function

    def register_records!
      ::GkRecords::Targets.register(TARGET, model: 'Group',
                                             visible: ->(g, user) { user.logged? && g.visible?(user) }, editable: ->(_g, user) { user.admin? },
                                             label: ->(g) { g.name }, url: ->(g) { { controller: 'groups', action: 'show', id: g.id } })
      SECTIONS.each { |k| ::GkRecords::Kinds.register_note(k, plugin: :gk_people, label_key: "label_gk_people_note_#{k}", target: TARGET) }
      EVENTS.each { |k| GkPeople.register_event!(k, target: TARGET) }
    end

    def ready? = defined?(::GkRecords) && ::GkRecords::Targets.find(TARGET)

    def write(group, kind, details)
      return unless ready? && ::GkRecords::Kinds.find(:event, kind)

      actor = User.current
      ::GkRecords::Events.write(group, kind, details: details, user: actor.logged? ? actor : nil, origin: actor.logged? ? 'human' : 'system')
    rescue StandardError => e
      Rails.logger.warn("[gk_people] group event #{kind} not written for group #{group.id}: #{e.message}")
    end

    # The text that holds for a section: the newest note of the kind that is neither voided nor corrected
    def current(group, kind)
      return nil unless ready?

      ::GkRecordsNote.for_target(TARGET, group.id).where(kind: kind, voided_at: nil, parent_id: nil).order(created_at: :desc, id: :desc)
                  .detect { |n| n.corrected_by.none? }
    end

    # The last thing that happened to the group: [time, user, what] from its notes and events, else nil
    def last_change(group)
      return nil unless ready?

      n = ::GkRecordsNote.for_target(TARGET, group.id).order(created_at: :desc, id: :desc).first
      e = ::GkRecordsEvent.for_target(TARGET, group.id).order(created_at: :desc, id: :desc).first
      latest = [n, e].compact.max_by(&:created_at)
      return nil unless latest

      what = latest.is_a?(::GkRecordsNote) ? ::GkRecords::Kinds.label(:note, latest.kind) : ::GkRecords::Kinds.label(:event, latest.kind)
      [latest.created_at, latest.user, what]
    end

    # While the function people.group_page is off, groups/show is core's own page, its source read once from core's
    # views and rendered as it is (the plugin's view stands first in the path). The same while the gate to GK GUI
    # Stuff is closed (gate.rb); then a source that cannot be read is raised on, since the page of people's own
    # cannot be drawn instead (its helpers are not in the views)
    def core_show_source
      @core_show_source ||= File.read(Rails.root.join('app', 'views', 'groups', 'show.html.erb'))
    rescue StandardError => e
      Rails.logger.warn("[gk_people] core's group page not found: #{e.message}")
      raise unless GkPeople.gui?

      nil
    end
  end

  # Core patch (documented in plugins/people): the group's own events from the model, so the admin pages, the API
  # and a sync are caught alike. user_added and user_removed are core's own callbacks on the membership.
  module GroupPatch
    def self.prepended(base)
      base.after_create_commit :gk_people_group_created
      base.after_update_commit :gk_people_group_renamed
    end

    private

    def gk_people_plain_group? = instance_of?(::Group)

    def gk_people_group_created
      GkPeople::Groups.write(self, 'group_created', { name: name }) if gk_people_plain_group?
    end

    def gk_people_group_renamed
      return unless gk_people_plain_group? && saved_change_to_lastname?

      GkPeople::Groups.write(self, 'group_renamed', { name: saved_change_to_lastname })
    end

    def user_added(user)
      super
      GkPeople::Groups.write(self, 'group_member_added', { member: GkPeople::Refs.person(user), user_id: user.id }) if gk_people_plain_group?
    end

    def user_removed(user)
      super
      GkPeople::Groups.write(self, 'group_member_removed', { member: GkPeople::Refs.person(user), user_id: user.id }) if gk_people_plain_group?
    end
  end
end

module GkPeople
  # The group's card in gui_stuff link_preview (people delivers the content, gui_stuff owns the card). Registered
  # behind the gate in init.rb (GkPeople.gui?, gate.rb).
  module GroupCard
    module_function

    def register!
      ::GkGuiStuff::Preview.register('group', pattern: '^/groups/(\\d+)$', plugin: :gk_people) do |id, user, _view|
        g = ::Group.visible(user).find_by(id: id)
        next nil unless g.instance_of?(::Group)

        members = g.users.visible(user).to_a.sort_by(&:name)
        purpose = GkPeople::Groups.ready? ? GkPeople::Groups.current(g, 'group_purpose') : nil
        last = GkPeople::Groups.ready? ? GkPeople::Groups.last_change(g) : nil
        # a member or the group not everyone may see has records' short text after the name
        fields = [[::I18n.t(:label_member_plural), ::GkGuiStuff::Preview.names(members.map { |m| Marks.text_name(m, user) }).presence || '-']]
        if last
          fields << [::I18n.t(:label_gk_people_card_changed),
                     "#{::GkGuiStuff::Preview.time(last[0], user)}, #{last[1] ? Marks.text_name(last[1], user) : ::GkRecords::Visibility.name_for(nil, user)}"] # last is there only with records
        end
        { title: Marks.text_name(g, user), subtitle: ::I18n.t(:text_gk_people_group_members, count: members.size), badges: [],
          text: ::GkGuiStuff::Preview.excerpt(purpose&.body), fields: fields }
      end
    end
  end
end
