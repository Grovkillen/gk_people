# frozen_string_literal: true

module GkPeople
  # Groups of people (plugins/people, groups): the records target, the events, and adding and removing members.
  # Called PersonGroups here, since GkPeople::Groups is what people does for Redmine's own groups.
  module PersonGroups
    TARGET = 'person_group'
    EVENTS = %w[person_group_created person_group_changed person_group_member_added person_group_member_removed].freeze

    module_function

    # records calls this from its init.rb (people loads first), with the registers
    def register_target!
      ::GkRecords::Targets.register(TARGET, model: 'GkPeopleGroup',
                                             visible: ->(_g, user) { Access.view?(user) }, editable: ->(_g, user) { Access.manage?(user) },
                                             label: ->(g) { g.name }, url: ->(g) { { controller: 'gk_people_groups', action: 'show', id: g.id } })
      EVENTS.each { |k| GkPeople.register_event!(k, target: TARGET) }
    end

    def write(group, kind, details)
      return unless defined?(::GkRecords) && ::GkRecords::Targets.find(TARGET)

      GkPeople.write_on(group, kind, details)
    end

    # A person into a group, last in it; nothing happens if she is already there. Returns the membership.
    def add(group, person, by: User.current)
      group.memberships.find_by(person_id: person.id) ||
        group.memberships.create!(person: person, position: (group.memberships.maximum(:position) || 0) + 1,
                                  created_by_id: by&.logged? ? by.id : nil, created_at: Time.current)
    end

    def remove(group, person)
      group.memberships.find_by(person_id: person.id)&.destroy
    end
  end

  # The Ruby API other plugins use (plugins/people, API): fields for quick picks, intake and agent for lookups.
  # Everything here answers with persons and groups, never with accounts; the account is person.user.
  module Api
    module_function

    # A person by an identifier: scheme key and value (a token too, compared by its digest)
    def find_by_identifier(scheme_key, value) = Identify.lookup(scheme_key, value)

    # Active persons matching a term (name, organization, e-mail, telephone, title, identifiers that are not tokens)
    # Not one merged into another
    def search(term, limit: 20) = ::GkPeoplePerson.active.not_merged.search(term).sorted.limit(limit).to_a

    # The members of a group, by its name (any case) or id, in the group's order; [] for an unknown group
    def group_members(name_or_id)
      g = name_or_id.is_a?(Integer) ? ::GkPeopleGroup.find_by(id: name_or_id) : ::GkPeopleGroup.active.find_by('lower(name) = ?', name_or_id.to_s.strip.downcase)
      g ? g.memberships.includes(:person).map(&:person).select(&:active) : []
    end

    def groups_of(person) = ::GkPeopleGroup.active.joins(:memberships).where(gk_people_group_members: { person_id: person.id }).sorted.to_a
  end
end
