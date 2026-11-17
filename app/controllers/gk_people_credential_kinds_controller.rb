# frozen_string_literal: true

# Administration, Intygstyper: the kinds of credential (data, not code). The key is set once (credentials and the
# requirements of responsibilities refer to it); a kind in use is switched off, never deleted. REST:
# GET /gk_people/credential_kinds.json for anyone who may see the registers.
class GkPeopleCredentialKindsController < GkPeopleBaseController
  feature_pages 'people.credentials'
  layout 'admin'
  accept_api_auth :index
  before_action :require_view, only: %i[index]
  before_action :require_admin, except: %i[index]
  before_action :find_kind, only: %i[edit update]

  def index
    @kinds = GkPeopleCredentialKind.sorted.to_a
    @in_use = GkPeopleCredential.not_revoked.group(:credential_key).count
    respond_to do |format|
      format.html { require_admin }
      format.json do
        render json: { credential_kinds: @kinds.map { |k| { id: k.id, key: k.key, name: k.name, applies_to: k.applies_to, renew_months: k.renew_months, active: k.active } } }
      end
    end
  end

  def new
    @kind = GkPeopleCredentialKind.new(applies_to: 'person', active: true, position: (GkPeopleCredentialKind.maximum(:position) || 0) + 1)
  end

  def create
    @kind = GkPeopleCredentialKind.new
    assign(@kind)
    return render(:new, status: 422) unless @kind.save

    flash[:notice] = l(:notice_successful_create)
    redirect_to gk_people_credential_kinds_path
  end

  def edit; end

  def update
    assign(@kind)
    return render(:edit, status: 422) unless @kind.save

    flash[:notice] = l(:notice_successful_update)
    redirect_to gk_people_credential_kinds_path
  end

  private

  def find_kind
    @kind = find_or_404(GkPeopleCredentialKind)
  end

  def assign(k)
    p = params.require(:kind)
    k.key = p[:key].to_s.strip unless k.persisted?
    k.assign_attributes(name: p[:name].to_s, description: p[:description].to_s.strip.presence,
                        applies_to: p[:applies_to].to_s.presence || 'person', renew_months: p[:renew_months].presence&.to_i,
                        position: p[:position].to_i, active: %w[1 true].include?(p[:active].to_s))
  end
end
