# frozen_string_literal: true

# Organisation (beside Personer, Organisationer and Grupper): the responsibilities with their holders, deputies,
# scopes and end dates, vacancies in red; a responsibility's page with its whole history; holding, ending and the
# deputy for those with gk_people_manage_responsibilities (never on one's own assignment). REST:
# GET /gk_people/responsibilities[.json], /gk_people/responsibilities/:id[.json] and
# /gk_people/responsibilities/:id/holder.json?scope_type=&scope_id=&on= (who acts, deputy chain included).
class GkPeopleResponsibilitiesController < GkPeopleBaseController
  feature_pages 'people.responsibilities'
  accept_api_auth :index, :show, :holder
  before_action :require_view
  before_action :require_responsibilities, only: %i[new create edit update assign end_assignment deputy add_rule remove_rule]
  # Rules and the role_sync flag decide which roles an account gets: the administrator's
  before_action :require_admin, only: %i[add_rule remove_rule]
  before_action :find_responsibility, except: %i[index new create]
  before_action :find_assignment, only: %i[end_assignment deputy]
  before_action :not_ones_own, only: %i[end_assignment deputy]

  def index
    @kind = params[:kind].presence_in(GkPeople::Responsibilities::KINDS)
    @group = GkPeopleGroup.find_by(id: params[:group_id]) if params[:group_id].present?
    @project = Project.find_by(id: params[:project_id]) if params[:project_id].present?
    scope = GkPeopleResponsibility.active.sorted
    scope = scope.where(kind: @kind) if @kind
    @responsibilities = scope.to_a
    rows = GkPeople::Responsibilities.in_force.where(responsibility_id: @responsibilities.map(&:id)).includes(:person, :deputy)
    rows = rows.where(scope_type: 'group', scope_id: @group.id) if @group
    rows = rows.where(scope_type: 'project', scope_id: @project.id) if @project
    @held = rows.to_a.group_by(&:responsibility_id)
    respond_to do |format|
      format.html
      format.json { render json: { responsibilities: @responsibilities.map { |r| resp_json(r, @held[r.id].to_a) } } }
    end
  end

  def show
    @history = @responsibility.assignments.includes(:person, :deputy, :created_by, :ended_by).sorted.to_a
    @now = @history.select(&:in_force?)
    respond_to do |format|
      format.html
      format.json { render json: { responsibility: resp_json(@responsibility, @now).merge(history: @history.map { |a| assignment_json(a) }) } }
    end
  end

  # Who acts now (or on a day) in a scope: the holder, or the deputy (at most two steps), or a vacancy
  def holder
    on = (params[:on].to_date rescue nil) || User.current.today
    scope = params[:scope_type].present? ? [params[:scope_type], params[:scope_id]] : nil
    r = GkPeople::Responsibilities.holder(@responsibility, scope, on: on)
    render json: { responsibility: @responsibility.key, on: on, vacancy: r[:vacancy], warning: r[:warning], via: r[:via], steps: r[:steps],
                   person: r[:person] && { id: r[:person].id, name: r[:person].name }, user_id: r[:user]&.id,
                   assignment_id: r[:assignment]&.id }
  end

  def new
    @responsibility = GkPeopleResponsibility.new(kind: 'function', active: true)
  end

  def create
    @responsibility = GkPeopleResponsibility.new
    assign_attrs(@responsibility)
    return render_errors(@responsibility) unless @responsibility.save

    flash[:notice] = l(:notice_successful_create)
    redirect_to gk_people_responsibility_path(@responsibility)
  end

  def edit; end

  def update
    assign_attrs(@responsibility)
    return render_errors(@responsibility) unless @responsibility.save

    flash[:notice] = l(:notice_successful_update)
    sync_roles
    redirect_to gk_people_responsibility_path(@responsibility)
  end

  # role_sync: a rule (which role, in which projects) on the responsibility, and removing one
  def add_rule
    rule = GkPeopleRoleRule.new(responsibility: @responsibility, created_by_id: User.current.id,
                              role: Role.givable.find_by(id: params[:role_id].to_i), target: params[:target].to_s)
    rule.project_id = params[:project_id].presence&.to_i if rule.target == 'project'
    rule.project_type_id = params[:project_type_id].presence&.to_i if rule.target == 'project_type'
    if rule.save
      GkPeople.write_on(@responsibility, 'responsibility_changed', { role_rule_added: "#{rule.role.name}: #{rule.target_label}" })
      flash[:notice] = l(:notice_successful_create)
      sync_roles
    else
      flash[:error] = rule.errors.full_messages.join(', ')
    end
    redirect_to gk_people_responsibility_path(@responsibility, anchor: 'gk-people-role-sync')
  end

  def remove_rule
    rule = @responsibility.role_rules.find_by(id: params[:rule_id].to_i)
    return render_404 unless rule

    GkPeople.write_on(@responsibility, 'responsibility_changed', { role_rule_removed: "#{rule.role&.name}: #{rule.target_label}" })
    rule.destroy
    flash[:notice] = l(:notice_successful_delete)
    sync_roles
    redirect_to gk_people_responsibility_path(@responsibility, anchor: 'gk-people-role-sync')
  end

  # A new holder: person, scope, from and until, deputy
  def assign
    a = GkPeopleAssignment.new(responsibility: @responsibility, created_by_id: User.current.id)
    a.person = GkPeoplePerson.active.find_by(id: params[:person_id].to_i)
    a.scope_type, a.scope_id = scope_param
    a.valid_from = (params[:valid_from].to_date rescue nil) || User.current.today
    a.valid_to = (params[:valid_to].to_date rescue nil)
    a.deputy_person_id = params[:deputy_person_id].presence&.to_i
    a.note = params[:note].to_s.strip.presence
    if a.person.nil?
      flash[:error] = l(:error_gk_people_choose_person)
    elsif (a.person.user_id && a.person.user_id == User.current.id) || own_person?(a.deputy_person_id)
      flash[:error] = l(:error_gk_people_not_ones_own)
    elsif a.save
      GkPeople::Responsibilities.write(a, 'responsibility_assigned', { valid_from: a.valid_from.to_s, valid_to: a.valid_to.to_s,
                                                                        deputy: GkPeople::Refs.register_person(a.deputy) })
      flash[:notice] = l(:notice_successful_create)
      warn_lacking(a.person, :warning_gk_people_holder_lacks)
      warn_lacking(a.deputy, :warning_gk_people_deputy_lacks) unless flash[:warning]
      sync_roles
    else
      flash[:error] = a.errors.full_messages.join(', ')
    end
    redirect_to gk_people_responsibility_path(@responsibility)
  end

  def end_assignment
    if GkPeople::Responsibilities.end!(@assignment)
      flash[:notice] = l(:notice_gk_people_assignment_ended)
      sync_roles
    else
      flash[:error] = @assignment.errors.full_messages.join(', ').presence || l(:error_gk_people_already_ended)
    end
    redirect_to gk_people_responsibility_path(@responsibility)
  end

  # The deputy and her period
  def deputy
    if own_person?(params[:deputy_person_id].presence&.to_i)
      flash[:error] = l(:error_gk_people_not_ones_own)
      return redirect_to(gk_people_responsibility_path(@responsibility))
    end
    @assignment.deputy_person_id = params[:deputy_person_id].presence&.to_i
    @assignment.deputy_valid_from = (params[:deputy_valid_from].to_date rescue nil)
    @assignment.deputy_valid_to = (params[:deputy_valid_to].to_date rescue nil)
    if @assignment.save
      GkPeople::Responsibilities.write(@assignment, 'responsibility_deputy_set', { deputy: GkPeople::Refs.register_person(@assignment.deputy),
                                                                                    from: @assignment.deputy_valid_from.to_s,
                                                                                    to: @assignment.deputy_valid_to.to_s })
      flash[:notice] = l(:notice_successful_update)
      warn_lacking(@assignment.deputy, :warning_gk_people_deputy_lacks)
      sync_roles
    else
      flash[:error] = @assignment.errors.full_messages.join(', ')
    end
    redirect_to gk_people_responsibility_path(@responsibility)
  end

  private

  # role_sync at once after a change (when it is on); what it did is on the responsibility's page
  def sync_roles
    run = GkPeople::RoleSync.run!(kind: 'change')
    return unless run && (run.added + run.removed).positive?

    flash[:notice] = [flash[:notice], l(:notice_gk_people_role_sync_done, added: run.added, removed: run.removed)].compact.join(' ')
  rescue StandardError => e
    Rails.logger.warn("[gk_people] role_sync after change: #{e.message}")
  end

  def require_responsibilities
    deny_access unless GkPeople::Responsibilities.manage?
  end

  def find_responsibility
    @responsibility = GkPeopleResponsibility.find_by(id: params[:id]) || GkPeopleResponsibility.find_by(key: params[:id].to_s)
    render_404 unless @responsibility
  end

  def find_assignment
    @assignment = @responsibility.assignments.find_by(id: params[:assignment_id].to_i)
    render_404 unless @assignment
  end

  # One's own assignment is changed by someone else
  def not_ones_own
    return unless @assignment.person.user_id && @assignment.person.user_id == User.current.id

    flash[:error] = l(:error_gk_people_not_ones_own)
    redirect_to gk_people_responsibility_path(@responsibility)
  end

  # Nor does one make oneself the deputy (the deputy gets the roles of the responsibility through role_sync)
  def own_person?(person_id)
    return false if person_id.blank?

    GkPeoplePerson.where(id: person_id, user_id: User.current.id).exists?
  end

  def scope_param
    case params[:scope].to_s
    when /\Aproject:(\d+)\z/ then ['project', Regexp.last_match(1).to_i]
    when /\Agroup:(\d+)\z/ then ['group', Regexp.last_match(1).to_i]
    else ['organization', nil]
    end
  end

  def assign_attrs(r)
    p = params.require(:responsibility).permit(:key, :name, :description, :kind, :position, :active, :wiki_page_id, :role_sync, required_credential_keys: [])
    r.key = p[:key] if r.new_record?
    r.name = p[:name]
    r.description = p[:description]
    r.kind = p[:kind] if p[:kind].present?
    r.position = p[:position].to_i
    r.active = %w[1 true].include?(p[:active].to_s) if p.key?(:active)
    r.wiki_page_id = p[:wiki_page_id].presence&.to_i
    r.role_sync = %w[1 true].include?(p[:role_sync].to_s) if p.key?(:role_sync) && GkPeople::RoleSync.ready? && User.current.admin?
    GkPeople::Credentials.set_required!(r, p[:required_credential_keys]) if p.key?(:required_credential_keys) && GkPeople::Credentials.ready?
  end

  # Assigning someone who lacks a required credential goes through, with a warning
  def warn_lacking(person, role_key)
    return unless person && GkPeople::Credentials.ready? && GkPeople.feature?('people.credentials')

    lack = GkPeople::Credentials.lacking(person, @responsibility)
    return if lack.empty?

    flash[:warning] = l(role_key, name: person.name, names: GkPeople::Credentials.kind_names(lack).join(', '))
  end

  def resp_json(r, rows)
    { id: r.id, key: r.key, name: r.name, kind: r.kind, description: r.description, active: r.active, wiki_page_id: r.wiki_page_id,
      required_credentials: GkPeople::Credentials.required_keys(r),
      vacancy: rows.empty?, holders: rows.map { |a| assignment_json(a) } }
  end

  def assignment_json(a)
    { id: a.id, person: { id: a.person_id, name: a.person&.name }, scope_type: a.scope_type, scope_id: a.scope_id,
      valid_from: a.valid_from, valid_to: a.valid_to, deputy: a.deputy && { id: a.deputy.id, name: a.deputy.name },
      deputy_valid_from: a.deputy_valid_from, deputy_valid_to: a.deputy_valid_to, note: a.note, ended_at: a.ended_at }
  end
end
