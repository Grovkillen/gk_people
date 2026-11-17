# frozen_string_literal: true

module GkPeople
  # responsibilities and assignments: who is responsible for what, with a deputy and a history that is never deleted.
  # * A responsibility is data (scenario), never code: key, name, description, kind (function: one holder per scope;
  #   area: several; object: one per object, chosen once cmdb is there), the role description as a wiki page.
  # * An assignment is a person holding it in a scope (the whole organization, a people group or a project), from a
  #   date and until one, with a deputy. Ending sets the end date; nothing is removed. One's own assignment is changed
  #   by someone else (gk_people_manage_responsibilities).
  # * The deputy steps in when the holder's account is locked, or during the period set on the assignment (absence
  #   from planning comes when planning is there). The chain is followed at most two steps (the deputy's own deputy in
  #   the same responsibility and scope); after that it is a vacancy, with a warning.
  # * Only lookup and view for now: Responsibilities.holder(key, scope), deputies(key, scope), for_person(person), the
  #   page Organisation and REST. Routing assignments and notices to the deputy comes with triggers; roles that
  #   follow from a responsibility are step 7 (role_sync).
  module Responsibilities
    KINDS = %w[function area object].freeze
    SCOPES = %w[organization group project].freeze # object: with cmdb
    EVENTS = %w[responsibility_assigned responsibility_ended responsibility_deputy_set].freeze
    MAX_STEPS = 2

    module_function

    # The questions about who holds what never ask the gate to GK GUI Stuff (gate.rb): the role sync reads them, and
    # a sync that saw no assignment in force would take away every role it gave. Only manage? asks it: it opens the
    # pages, which are closed then.
    def ready?
      ::GkPeopleAssignment.table_exists?
    rescue StandardError
      false
    end

    def manage?(user = ::User.current) = GkPeople.gui? && (user.admin? || user.allowed_to?(:gk_people_manage_responsibilities, nil, global: true))

    def find(key) = ::GkPeopleResponsibility.find_by(key: key.to_s)

    # [scope_type, scope_id] for a scope given as a Project, a people group, a pair or nil (the whole organization)
    def scope_of(scope)
      case scope
      when nil then ['organization', nil]
      when ::Project then ['project', scope.id]
      when ::GkPeopleGroup then ['group', scope.id]
      when Array then [scope[0].to_s, scope[1]&.to_i]
      else raise ArgumentError, 'scope'
      end
    end

    # The assignments in force, also while the gate is closed (gate.rb)
    def in_force(on = ::User.current.today) = ::GkPeopleAssignment.in_force(on)

    # The assignments in force for a responsibility in a scope; a scope without its own holder falls back to the
    # whole organization
    def holders(key, scope = nil, on: ::User.current.today)
      r = key.is_a?(::GkPeopleResponsibility) ? key : find(key)
      return [] unless r

      type, id = scope_of(scope)
      rows = in_force(on).where(responsibility_id: r.id, scope_type: type, scope_id: id).includes(:person, :deputy).to_a
      rows = in_force(on).where(responsibility_id: r.id, scope_type: 'organization').includes(:person, :deputy).to_a if rows.empty? && type != 'organization'
      rows
    end

    # Not there to act: inactive, her account locked, or inside the period her deputy covers on her assignment
    def unavailable?(person, assignment, on)
      return true if person.nil? || !person.active
      return true if person.user&.locked?

      assignment.present? && assignment.deputy_period_covers?(on)
    end

    # Who acts for a responsibility in a scope: { person:, user:, via: :holder/:deputy, steps:, assignment:,
    # warning: nil, vacancy: false }, or a vacancy { person: nil, vacancy: true, warning: } (nil: nobody holds it;
    # :no_deputy: the holder is away and nobody stands in; :chain_too_long: more than two steps). With several
    # holders (an area), the first one who is there.
    def holder(key, scope = nil, on: ::User.current.today)
      rows = holders(key, scope, on: on)
      return { person: nil, vacancy: true, warning: nil } if rows.empty?

      rows.each { |a| return result(a.person, :holder, 0, a) unless unavailable?(a.person, a, on) }
      first = rows.first
      current = first
      1.upto(MAX_STEPS) do |step|
        deputy = current.deputy
        return { person: nil, vacancy: true, warning: :no_deputy, assignment: first } unless deputy

        own = in_force(on).find_by(responsibility_id: first.responsibility_id, scope_type: first.scope_type,
                                   scope_id: first.scope_id, person_id: deputy.id)
        return result(deputy, :deputy, step, first) unless unavailable?(deputy, own, on)
        return { person: nil, vacancy: true, warning: :no_deputy, assignment: first } unless own

        current = own
      end
      { person: nil, vacancy: true, warning: :chain_too_long, assignment: first }
    end

    def result(person, via, steps, assignment)
      { person: person, user: person&.user, via: via, steps: steps, assignment: assignment, warning: nil, vacancy: false }
    end

    def deputies(key, scope = nil, on: ::User.current.today) = holders(key, scope, on: on).map(&:deputy).compact.uniq

    # What a person holds and stands in for now: { held: [assignments], deputy_for: [assignments] }
    def for_person(person, on: ::User.current.today)
      { held: in_force(on).where(person_id: person.id).includes(:responsibility).to_a,
        deputy_for: in_force(on).where(deputy_person_id: person.id).includes(:responsibility, :person).to_a }
    end

    # The vacancies: active responsibilities with no holder in force anywhere
    def vacancies(on = ::User.current.today)
      held = in_force(on).select(:responsibility_id)
      ::GkPeopleResponsibility.active.where.not(id: held).sorted
    end

    # The scope stays "group:12" as before; a people group as scope is also named as records' reference of the kind
    # person_group in scope_group (declared as a person field), so records names it to those who may see it and a
    # listener can follow it
    def write(assignment, kind, details)
      extra = { responsibility: assignment.responsibility.key, scope: [assignment.scope_type, assignment.scope_id].compact.join(':') }
      group = assignment.scope_type == 'group' && assignment.scope_id ? Refs.register_group(assignment.scope_id) : nil
      extra[:scope_group] = group if group
      GkPeople.write_on(assignment.person, kind, details.merge(extra))
    end

    # Ends an assignment from a day (today: the last day was yesterday); nothing is removed
    def end!(assignment, on: ::User.current.today, by: ::User.current)
      return false if assignment.ended_at

      assignment.valid_to = [assignment.valid_to, on - 1].compact.min
      assignment.ended_at = Time.current
      assignment.ended_by_id = by&.logged? ? by.id : nil
      ok = assignment.save
      write(assignment, 'responsibility_ended', { valid_to: assignment.valid_to.to_s }) if ok
      ok
    end
  end
end
