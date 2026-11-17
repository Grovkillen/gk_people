# frozen_string_literal: true

# Organisationer (top menu): the list with search, the organization's page with its persons, new and edit, and the
# REST /gk_people/organizations[.json]. The approval columns are set by hand until the supplier assessment
# sets them; who and when follow the status. Nothing is deleted: an organization is made inactive.
class GkPeopleOrganizationsController < GkPeopleBaseController
  accept_api_auth :index, :show, :create, :update
  before_action :require_view
  before_action :require_manage, only: %i[new create edit update]
  before_action :find_org, only: %i[show edit update]

  def index
    scope = GkPeopleOrganization.all
    @q = params[:q].to_s.strip
    scope = scope.search(@q) if @q.present?
    scope = scope.with_kind(params[:kind]) if params[:kind].present?
    if params[:info_source].present?
      term = params[:info_source].to_s
      by_hand = scope.where(GkPeople::Sql.like(GkPeopleOrganization.arel_table[:info_source], term))
      # Or a field set by a reading of that source (an import no longer fills info_source)
      if GkPeople::Import.readings?
        read = GkRecordsFieldOrigin.joins(:reading).where(target_type: 'organization')
                                   .where(GkPeople::Sql.like(GkRecordsReading.arel_table[:source_label], term)).select(:target_id)
        scope = by_hand.or(scope.where(id: read))
      else
        scope = by_hand
      end
    end
    scope = scope.where('lower(gk_people_organizations.city) = lower(?)', params[:city].to_s.strip) if params[:city].present?
    scope = scope.where(approval_status: params[:approval_status]) if GkPeople::APPROVAL.include?(params[:approval_status]) && (api_request? || GkPeople.feature?('people.approval'))
    scope = scope.where(source: params[:source].to_s) if params[:source].present?
    # One merged into another is left out with the inactive ones (records' link same_as)
    scope = scope.where(active: true).not_merged unless params[:active] == 'all'
    # Tags chosen in the box Taggar in the sidebar (tags), with the descendants the search finds; the box counts the
    # list's own ids before paging
    scope = ::GkTags::Sidebar.filter_objects(scope, 'GkPeopleOrganization', params[:tag]) if params[:tag].present? && defined?(::GkTags::Sidebar) && ::GkTags::Sidebar.on?
    @gk_tags_ids_sql = scope.reorder(nil).distinct.pluck("#{scope.table_name}.id").presence&.join(',') || '0' if defined?(::GkTags::Sidebar) && ::GkTags::Sidebar.on?
    @count = scope.count
    @pages = Paginator.new(@count, per_page, params['page'])
    @orgs = scope.sorted.offset(@pages.offset).limit(@pages.per_page).to_a
    @person_counts = GkPeoplePerson.where(organization_id: @orgs.map(&:id)).group(:organization_id).count
    respond_to do |format|
      format.html
      format.json { render json: { organizations: @orgs.map { |o| org_json(o) }, total_count: @count, offset: @pages.offset, limit: @pages.per_page } }
    end
  end

  def show
    @persons = @org.persons.not_merged.to_a # Not the ones merged into another
    respond_to do |format|
      format.html
      format.json do
        render json: { organization: org_json(@org).merge(persons: @persons.map { |p| { id: p.id, name: p.name } },
                                                          children: @org.children.map { |c| { id: c.id, name: c.name } }) }
      end

    end
  end

  def new
    @org = GkPeopleOrganization.new
    @org.kind_keys = [params[:kind]] if params[:kind].present? && GkPeopleOrgKind.exists?(key: params[:kind].to_s)
  end

  def create
    @org = GkPeopleOrganization.new(created_by_id: User.current.id)
    assign(@org)
    return render_errors(@org) unless @org.save

    mark_owner(@org)

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_organization_path(@org) }
      format.json { render json: { organization: org_json(@org) }, status: :created }
    end
  end

  def edit; end

  def update
    assign(@org)
    return render_errors(@org) unless @org.save

    mark_owner(@org)

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_people_organization_path(@org) }
      format.json { render json: { organization: org_json(@org) } }
    end
  end

  private

  def find_org
    @org = find_or_404(GkPeopleOrganization)
  end

  # source and external_id only by the administrator (the sync sets them itself)
  def assign(org)
    allowed = %i[name short_name org_no address city sni country phone email website notes active approval_status approval_valid_to risk_class info_source info_source_on
                 parent_id location_n location_e location_crs org_form size_class deregistered_on]

    allowed += %i[source external_id] if User.current.admin?
    # The picture folder is a path on the server: only the administrator
    allowed += %i[avatar_folder_on avatar_folder avatar_name_rule avatar_hide_allowed name_hide_allowed] if User.current.admin?
    raw = params.require(:organization)
    p = raw.permit(*allowed)
    # the kinds: the form's list (kind_keys[], an empty one clears), or kinds (a list) or kind (one) in REST
    kinds = raw[:kind_keys] || raw[:kinds] || raw[:kind]
    org.kind_keys = Array(kinds).map(&:to_s).reject(&:empty?) if (raw.key?(:kind_keys) || raw.key?(:kinds) || raw.key?(:kind)) && !org.owned_by_source?(:kind_keys)
    p = p.to_h.reject { |k, _| org.owned_by_source?(k) }
    p['info_source_on'] = p['info_source_on'].presence if p.key?('info_source_on')
    p.delete('source') if org.persisted?
    p.delete('external_id') if org.persisted? && org.external_id.present?
    p['active'] = %w[1 true].include?(p['active'].to_s) if p.key?('active')
    %w[avatar_folder_on avatar_hide_allowed name_hide_allowed].each { |b| p[b] = %w[1 true].include?(p[b].to_s) if p.key?(b) }
    p['avatar_folder'] = p['avatar_folder'].to_s.strip.presence if p.key?('avatar_folder')
    p['approval_valid_to'] = p['approval_valid_to'].presence if p.key?('approval_valid_to')
    # The parent by id (the form) or, in REST, parent: an organization number or an id; empty clears
    p['parent_id'] = p['parent_id'].presence if p.key?('parent_id')
    p['parent_id'] = parent_from(raw[:parent]) if raw.key?(:parent)
    %w[location_n location_e location_crs org_form size_class deregistered_on].each { |f| p[f] = p[f].to_s.strip.presence if p.key?(f) }
    org.assign_attributes(p)
    # The tags (gk_tags' register, when tags is there), text from REST or a list from the form's chooser; tags reads
    # both and checks them on save
    org.gk_tag_list = raw[:gk_tag_list] if raw.key?(:gk_tag_list) && org.respond_to?(:gk_tag_list=)
  end

  # An organization number (digits, at least six) or an id; an unknown one gives an id that is not there, so the model
  # refuses it
  def parent_from(value)
    v = value.to_s.strip
    return nil if v.empty?

    d = v.gsub(/\D/, '')
    return d.to_i if d.size < 6

    GkPeopleOrganization.by_number(d).order(:id).pick(:id) || 0
  end


  # The instance's owner: only an administrator marks it; '*' for every language or a list of languages
  def mark_owner(org)
    raw = params[:organization]
    return unless raw&.key?(:owner_langs) && User.current.admin?

    value = Array(raw[:owner_langs]).join(',').delete(' ')
    GkPeople::Owner.mark!(org, value) if value != org.owner_langs.to_s
  rescue ActiveRecord::RecordInvalid => e
    flash[:error] = e.record.errors.full_messages.join(' ')
  end

  def render_errors(record)
    @org = record
    super
  end
end
