# frozen_string_literal: true

# Administration, Organisationstyper: the kinds of organization as data. The key is set once (sync, import and REST
# name kinds by it); a kind in use is switched off, never deleted. REST: GET /gk_people/org_kinds.json for anyone who
# may see the registers.
class GkPeopleOrgKindsController < GkPeopleBaseController
  layout 'admin'
  accept_api_auth :index
  before_action :require_view, only: %i[index]
  before_action :require_admin, except: %i[index]
  before_action :find_kind, only: %i[edit update]

  def index
    @kinds = GkPeopleOrgKind.sorted.to_a
    @in_use = GkPeopleOrganizationKind.group(:kind_id).count
    respond_to do |format|
      format.html { require_admin }
      format.json do
        render json: { org_kinds: @kinds.map { |k| { id: k.id, key: k.key, name: k.name, description: k.description, position: k.position, active: k.active, in_use: @in_use[k.id].to_i } } }
      end
    end
  end

  def new
    @kind = GkPeopleOrgKind.new(active: true, position: (GkPeopleOrgKind.maximum(:position) || 0) + 1)
  end

  def create
    @kind = GkPeopleOrgKind.new
    assign(@kind)
    return render(:new, status: 422) unless @kind.save

    flash[:notice] = l(:notice_successful_create)
    redirect_to gk_people_org_kinds_path
  end

  def edit; end

  def update
    assign(@kind)
    return render(:edit, status: 422) unless @kind.save

    flash[:notice] = l(:notice_successful_update)
    redirect_to gk_people_org_kinds_path
  end

  private

  def find_kind
    @kind = find_or_404(GkPeopleOrgKind)
  end

  def assign(k)
    p = params.require(:kind)
    k.key = p[:key].to_s.strip unless k.persisted?
    k.assign_attributes(name: p[:name].to_s, description: p[:description].to_s.strip.presence,
                        position: p[:position].to_i, active: %w[1 true].include?(p[:active].to_s))
  end
end
