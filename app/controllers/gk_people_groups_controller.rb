# frozen_string_literal: true

# Grupper (beside Personer and Organisationer): groups of people with their members, and the REST
# /gk_people/groups[.json] and /gk_people/groups/:id/members[.json]. A member is found by searching on the
# group's page (no script needed). A group is made inactive, never deleted; a membership ended is removed and kept
# as an event on the group.
class GkPeopleGroupsController < GkPeopleBaseController
  feature_pages 'people.groups'
  accept_api_auth :index, :show, :create, :update, :members, :add_member, :remove_member
  before_action :require_view
  before_action :require_manage, only: %i[new create edit update add_member remove_member]
  before_action :find_group, except: %i[index new create]

  def index
    scope = GkPeopleGroup.all
    @q = params[:q].to_s.strip
    scope = scope.search(@q) if @q.present?
    scope = scope.where(active: true) unless params[:active] == 'all'
    @count = scope.count
    @pages = Paginator.new(@count, per_page, params['page'])
    @groups = scope.sorted.offset(@pages.offset).limit(@pages.per_page).to_a
    @member_counts = GkPeopleGroupMember.where(group_id: @groups.map(&:id)).group(:group_id).count
    respond_to do |format|
      format.html
      format.json { render json: { groups: @groups.map { |g| group_json(g) }, total_count: @count, offset: @pages.offset, limit: @pages.per_page } }
    end
  end

  def show
    @members = @group.memberships.includes(person: :organization).to_a
    @q = params[:q].to_s.strip
    if @q.present? && GkPeople::Access.manage?
      @found = GkPeoplePerson.active.search(@q).where.not(id: @members.map(&:person_id)).sorted.limit(20).to_a
    end
    respond_to do |format|
      format.html
      format.json { render json: { group: group_json(@group).merge(members: @members.map { |m| member_json(m) }) } }
    end
  end

  def members
    render json: { members: @group.memberships.includes(:person).map { |m| member_json(m) } }
  end

  def new
    @group = GkPeopleGroup.new(active: true)
  end

  def create
    @group = GkPeopleGroup.new(created_by_id: User.current.id)
    assign(@group)
    return render_errors(@group) unless @group.save

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_group_path(@group) }
      format.json { render json: { group: group_json(@group) }, status: :created }
    end
  end

  def edit; end

  def update
    assign(@group)
    return render_errors(@group) unless @group.save

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_people_group_path(@group) }
      format.json { render json: { group: group_json(@group) } }
    end
  end

  def add_member
    return respond_member_error(:error_gk_people_members_by_source) if @group.owned_by_source?(:members)

    person = GkPeoplePerson.find_by(id: params[:person_id])
    return respond_member_error(:error_gk_people_no_such_person) unless person

    m = GkPeople::PersonGroups.add(@group, person)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_gk_people_member_added, name: person.name); redirect_to gk_people_group_path(@group) }
      format.json { render json: { member: member_json(m) }, status: :created }
    end
  end

  def remove_member
    return respond_member_error(:error_gk_people_members_by_source) if @group.owned_by_source?(:members)

    person = GkPeoplePerson.find_by(id: params[:person_id])
    return respond_member_error(:error_gk_people_no_such_person) unless person

    GkPeople::PersonGroups.remove(@group, person)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_gk_people_member_removed, name: person.name); redirect_to gk_people_group_path(@group) }
      format.json { head :no_content }
    end
  end

  private

  def find_group
    @group = find_or_404(GkPeopleGroup)
  end

  # Only what was sent is changed (a PUT with the description alone keeps the name); source and external id are set once,
  # and only by the administrator (the sync sets them itself)
  def assign(group)
    allowed = %i[name description active]
    allowed += %i[source external_id] if User.current.admin?
    p = params.require(:group).permit(*allowed)
    attrs = {}
    attrs[:name] = p[:name] if p.key?(:name)
    attrs[:description] = p[:description].to_s.strip.presence if p.key?(:description)
    attrs[:active] = %w[1 true].include?(p[:active].to_s) if p.key?(:active)
    if !group.persisted? && User.current.admin?
      attrs[:source] = p[:source].presence
      attrs[:external_id] = p[:external_id].presence
    end
    attrs = attrs.reject { |k, _| group.owned_by_source?(k) }
    group.assign_attributes(attrs)
  end

  def respond_member_error(key)
    respond_to do |format|
      format.html { flash[:error] = l(key); redirect_to gk_people_group_path(@group) }
      format.json { render json: { errors: [l(key)] }, status: 422 }
    end
  end

  def group_json(g)
    { id: g.id, name: g.name, description: g.description, active: g.active, source: g.source, external_id: g.external_id,
      created_on: g.created_at, updated_on: g.updated_at }
  end

  def member_json(m)
    { person_id: m.person_id, name: m.person&.name, position: m.position, added_on: m.created_at }
  end

  def render_errors(record)
    @group = record
    super
  end
end
