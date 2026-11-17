# frozen_string_literal: true

# Intyg (beside Personer, Organisationer, Grupper and Organisation): the credentials that need attention (expiring,
# lapsed and not replaced) or all of them, filtered by kind and holder; adding, correcting and revoking for those
# with gk_people_manage_credentials (never removing), with the proof as attachments. Who sees which credential is
# GkPeople::Credentials.visible?. REST: GET /gk_people/credentials.json[?person_id=|organization_id=|kind=|status=].
class GkPeopleCredentialsController < GkPeopleBaseController
  feature_pages 'people.credentials'
  accept_api_auth :index
  before_action :require_view
  before_action :require_credentials, except: %i[index]
  before_action :find_credential, only: %i[edit update revoke]

  def index
    @kinds = GkPeopleCredentialKind.sorted.to_a
    @kind = params[:kind].presence_in(@kinds.map(&:key))
    @status = params[:status].presence_in(%w[attention all]) || 'attention'
    @holder_type = params[:holder].presence_in(%w[person organization])
    rows =
      if params[:person_id].present? || params[:organization_id].present?
        holder = params[:person_id].present? ? GkPeoplePerson.find_by(id: params[:person_id]) : GkPeopleOrganization.find_by(id: params[:organization_id])
        return render_404 unless holder

        GkPeople::Credentials.for_holder(holder)
      elsif @status == 'attention'
        GkPeople::Credentials.attention
      else
        GkPeopleCredential.includes(:person, :organization).sorted.to_a.select(&:visible?)
      end
    rows = rows.select { |c| c.credential_key == @kind } if @kind
    rows = rows.select { |c| c.holder_type == @holder_type } if @holder_type
    @credentials = rows
    respond_to do |format|
      format.html
      format.json { render json: { credentials: rows.map { |c| credential_json(c) } } }
    end
  end

  def new
    @credential = GkPeopleCredential.new(issued_on: User.current.today)
    holder_from_params(@credential)
    return render_404 unless @credential.holder

    @credential.credential_key = params[:kind] if params[:kind].present?
  end

  def create
    @credential = GkPeopleCredential.new(created_by_id: User.current.id)
    holder_from_params(@credential)
    return render_404 unless @credential.holder

    @credential.credential_key = params.dig(:credential, :credential_key).to_s
    assign(@credential)
    @credential.save_attachments(params[:attachments])
    return render(:new, status: 422) unless @credential.save

    render_attachment_warning_if_needed(@credential)
    GkPeople::Credentials.write(@credential, 'credential_added', { issued_on: @credential.issued_on.to_s, valid_to: @credential.valid_to.to_s,
                                                                    issuer: @credential.issuer })
    flash[:notice] = l(:notice_successful_create)
    redirect_to holder_path(@credential)
  end

  def edit; end

  def update
    assign(@credential)
    @credential.save_attachments(params[:attachments])
    return render(:edit, status: 422) unless @credential.save

    render_attachment_warning_if_needed(@credential)
    ch = @credential.saved_changes.except('updated_at').transform_values { |v| v.map(&:to_s) }
    GkPeople::Credentials.write(@credential, 'credential_changed', ch) if ch.any?
    flash[:notice] = l(:notice_successful_update)
    redirect_to holder_path(@credential)
  end

  # Revoked, never removed: a mistake or a withdrawn credential stays as history, with the reason
  def revoke
    # The place people.credential_revoke decides; without records the reason is required as before
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.credential_revoke', params[:reason]) : nil
    if check && !check.ok
      flash[:error] = check.error
    elsif check.nil? && params[:reason].to_s.strip.empty?
      flash[:error] = l(:error_gk_people_reason_required)
    elsif GkPeople::Credentials.revoke!(@credential, reason: check ? check.text : params[:reason])
      flash[:notice] = l(:notice_gk_people_credential_revoked)
    else
      flash[:error] = @credential.errors.full_messages.join(', ').presence || l(:error_gk_people_already_revoked)
    end
    redirect_to holder_path(@credential)
  end

  private

  def require_credentials
    deny_access unless GkPeople::Credentials.manage?
  end

  def find_credential
    @credential = find_or_404(GkPeopleCredential)
  end

  def holder_from_params(c)
    if params[:person_id].present?
      c.person = GkPeoplePerson.find_by(id: params[:person_id])
    elsif params[:organization_id].present?
      c.organization = GkPeopleOrganization.find_by(id: params[:organization_id])
    end
  end

  def assign(c)
    p = params.require(:credential).permit(:issued_on, :valid_to, :issuer, :reference, :note)
    c.issued_on = (p[:issued_on].to_date rescue nil)
    c.valid_to = (p[:valid_to].to_date rescue nil)
    c.issuer = p[:issuer].to_s.strip.presence
    c.reference = p[:reference].to_s.strip.presence
    c.note = p[:note].to_s.strip.presence
  end

  def holder_path(c)
    c.person_id ? gk_people_person_path(c.person_id, anchor: 'gk-people-credentials') : gk_people_organization_path(c.organization_id, anchor: 'gk-people-credentials')
  end

  def credential_json(c)
    { id: c.id, kind: c.credential_key, name: c.kind&.name, status: c.status,
      person: c.person && { id: c.person.id, name: c.person.name }, organization: c.organization && { id: c.organization.id, name: c.organization.name },
      issued_on: c.issued_on, valid_to: c.valid_to, issuer: c.issuer, reference: c.reference, revoked_at: c.revoked_at,
      attachments: c.attachments.map { |a| { id: a.id, filename: a.filename, content_url: download_named_attachment_url(a, a.filename) } } }
  end
end
