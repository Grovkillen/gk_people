# frozen_string_literal: true

# Personer (top menu): the list with search, the person's page, new and edit, the link to an account, and the REST
# /gk_people/persons[.json] with identify.json. Nothing is deleted: a person who is no longer relevant is
# made inactive (merging and anonymizing come later, plugins/people persons and Integritet).
class GkPeoplePersonsController < GkPeopleBaseController
  accept_api_auth :index, :show, :create, :update, :identify, :autocomplete
  before_action :require_view
  before_action :require_manage, only: %i[new create edit update link unlink]
  before_action :require_admin, only: %i[fill_accounts unlink]
  before_action :find_person, only: %i[show edit update link unlink]
  before_action :require_admin_to_relink, only: %i[link]

  def index
    scope = GkPeoplePerson.includes(:organization, :user)
    @q = params[:q].to_s.strip
    scope = scope.search(@q) if @q.present?
    scope = scope.where(kind: params[:kind]) if GkPeople::PERSON_KINDS.include?(params[:kind])
    scope = scope.where(organization_id: params[:organization_id].to_i) if params[:organization_id].present?
    if params[:group_id].present? && (api_request? || GkPeople.feature?('people.groups')) # The filter is a page of people.groups
      @group = GkPeopleGroup.find_by(id: params[:group_id].to_i)
      scope = scope.where(id: GkPeopleGroupMember.where(group_id: params[:group_id].to_i).select(:person_id))
    end
    case params[:account]
    when 'yes' then scope = scope.where.not(user_id: nil)
    when 'no' then scope = scope.where(user_id: nil)
    end
    if params[:identifier].to_s.include?(':')
      key, value = params[:identifier].split(':', 2)
      found = GkPeople::Identify.lookup(key, value)
      scope = scope.where(id: found&.id)
    end
    # One merged into another is left out with the inactive ones (records' link same_as)
    scope = scope.where(active: true).not_merged unless params[:active] == 'all'
    # Tags chosen in the box Taggar in the sidebar (tags), with the descendants the search finds; the box counts the
    # list's own ids before paging
    scope = ::GkTags::Sidebar.filter_objects(scope, 'GkPeoplePerson', params[:tag]) if params[:tag].present? && defined?(::GkTags::Sidebar) && ::GkTags::Sidebar.on?
    @gk_tags_ids_sql = scope.reorder(nil).distinct.pluck("#{scope.table_name}.id").presence&.join(',') || '0' if defined?(::GkTags::Sidebar) && ::GkTags::Sidebar.on?
    @count = scope.count
    @pages = Paginator.new(@count, per_page, params['page'])
    @persons = scope.sorted.offset(@pages.offset).limit(@pages.per_page).to_a
    @unlinked = GkPeople::Accounts.unlinked_accounts.count if User.current.admin?
    respond_to do |format|
      format.html
      format.json { render json: { persons: @persons.map { |p| person_json(p) }, total_count: @count, offset: @pages.offset, limit: @pages.per_page } }
    end
  end

  # The search other pages and plugins ask (the REST API and the Ruby API): active persons by name, organization, e-mail,
  # telephone, title or an identifier that is not a token; at most 20, for a picker. user_id as in person_json
  # (api_account_id): null with user_hidden for an account the asker may not see
  def autocomplete
    term = params[:q].to_s.strip
    persons = term.length < 2 ? [] : GkPeople::Api.search(term, limit: (params[:limit].presence || 20).to_i.clamp(1, 50))
    render json: { persons: persons.map { |p| { id: p.id, name: p.name, organization: p.organization&.name, title: p.title }.merge(api_account_id(:user_id, p.user_id, p.user)) } }
  end

  def show
    @groups = GkPeople::Api.groups_of(@person)
    @identifiers = @person.identifiers.includes(:scheme).to_a
    @channels = GkPeople.channels_for(@person, { title: @person.name, url: request.original_url })
    # only accounts the viewer may see by core's rule (Accounts.visible_unlinked_accounts)
    @accounts = GkPeople::Accounts.visible_unlinked_accounts(User.current).to_a if GkPeople::Access.manage? && @person.user_id.nil?
    respond_to do |format|
      format.html
      format.json { render json: { person: person_json(@person, full: true) } }
    end
  end

  def new
    @person = GkPeoplePerson.new(kind: params[:kind].presence_in(GkPeople::PERSON_KINDS) || 'external',
                               organization_id: params[:organization_id].presence)
  end

  def create
    @person = GkPeoplePerson.new(created_by_id: User.current.id)
    assign(@person)
    return render_errors(@person) unless @person.save

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_person_path(@person) }
      format.json { render json: { person: person_json(@person, full: true) }, status: :created }
    end
  end

  def edit; end

  def update
    assign(@person)
    return render_errors(@person) unless @person.save

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_people_person_path(@person) }
      format.json { render json: { person: person_json(@person, full: true) } }
    end
  end

  # The account as an identifier: link one that has no person (gk_people_manage), or break the link (with a reason
  # when given); breaking or changing an existing link is the administrator's (role_sync gives roles to the account)
  def link
    user = User.find_by(id: params[:user_id])
    # an account the viewer may not see (an id sent directly) is answered as one that does not exist, so the answer
    # never tells that it is there
    user = nil if user && !GkPeople::Accounts.visible_account?(user, User.current)
    # The place people.account_link decides (off keeps no reason)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.account_link', params[:reason]) : nil
    if check && !check.ok
      flash[:error] = check.error
      return redirect_to gk_people_person_path(@person)
    end

    reason = check ? check.text : params[:reason].presence
    error = user ? GkPeople::Accounts.link!(@person, user, how: 'manual', reason: reason) : l(:error_gk_people_not_an_account)
    error ? flash[:error] = error : flash[:notice] = l(:notice_gk_people_linked, login: user.login)
    redirect_to gk_people_person_path(@person)
  end

  def unlink
    # The place people.account_unlink decides (off keeps no reason)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.account_unlink', params[:reason]) : nil
    if check && !check.ok
      flash[:error] = check.error
      return redirect_to gk_people_person_path(@person)
    end

    error = GkPeople::Accounts.unlink!(@person, reason: check ? check.text : params[:reason].presence)
    error ? flash[:error] = error : flash[:notice] = l(:notice_gk_people_unlinked)
    redirect_to gk_people_person_path(@person)
  end

  # Every account without a person gets one (after installing on an instance that already has accounts)
  def fill_accounts
    n = GkPeople::Accounts.fill_missing!
    flash[:notice] = l(:notice_gk_people_filled, count: n)
    redirect_to gk_people_persons_path
  end

  # POST identify.json with scheme and value: the person, or 404 (People::Identify; also a reader's token); at most
  # IDENTIFY_PER_MINUTE a minute for each account, so it is no oracle for counting tokens (429 above that)
  def identify
    return render(json: { error: l(:error_gk_people_identify_too_many, count: IDENTIFY_PER_MINUTE) }, status: 429) if identify_throttled?

    person = GkPeople::Identify.lookup(params[:scheme], params[:value])
    return render(json: { error: 'not found' }, status: 404) unless person

    render json: { person: person_json(person) }
  end

  private

  IDENTIFY_PER_MINUTE = 10

  # Counted in Rails.cache per account and minute; a cache that fails never stops the lookup
  def identify_throttled?
    key = "gk_people/identify/#{User.current.id}/#{Time.current.to_i / 60}"
    n = Rails.cache.read(key).to_i + 1
    Rails.cache.write(key, n, expires_in: 2.minutes)
    n > IDENTIFY_PER_MINUTE
  rescue StandardError => e
    Rails.logger.warn("[gk_people] identify not counted: #{e.class}: #{e.message}")
    false
  end

  def find_person
    @person = find_or_404(GkPeoplePerson)
  end

  # A person who already has an account is moved to another one only by the administrator
  def require_admin_to_relink
    require_admin if @person.user_id.present?
  end

  # What the source owns is not changed here (a synced person); the account is linked on its own (link); source and
  # external_id only by the administrator (the sync sets them itself)
  def assign(person)
    allowed = %i[display_name first_name last_name organization_id kind email phone title languages notes active info_source info_source_on]
    allowed += %i[source external_id] if User.current.admin?
    raw = params.require(:person)
    p = raw.permit(*allowed)
    p = p.to_h.reject { |k, _| person.owned_by_source?(k) }
    p.delete('source') if person.persisted?
    p.delete('external_id') if person.persisted? && person.external_id.present?
    p['organization_id'] = p['organization_id'].presence
    p['info_source_on'] = p['info_source_on'].presence if p.key?('info_source_on')
    p['active'] = %w[1 true].include?(p['active'].to_s) if p.key?('active')
    person.assign_attributes(p)
    # The tags (gk_tags' register, when tags is there), text from REST or a list from the form's chooser; tags reads
    # both and checks them on save
    person.gk_tag_list = raw[:gk_tag_list] if raw.key?(:gk_tag_list) && person.respond_to?(:gk_tag_list=)
  end
end
