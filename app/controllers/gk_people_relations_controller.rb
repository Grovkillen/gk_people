# frozen_string_literal: true

# An organization's relations to us: a new relation (kind, project or global, from, to, reason) and the end of one
# (a day and a reason). Nothing is deleted.
# For those who may manage the registers; a relation in a project also needs the project to be visible to them.
# REST: POST /gk_people/organizations/:id/relations.json, PATCH .../relations/:relation_id/end.json.
class GkPeopleRelationsController < GkPeopleBaseController
  accept_api_auth :create, :end_relation
  before_action :require_manage
  before_action :find_org

  def create
    kind = GkPeopleOrgKind.find_by(key: params[:kind].to_s)
    project = params[:project_id].present? ? Project.visible.find_by(id: params[:project_id]) : nil
    return respond_error(l(:error_gk_people_unknown_org_kind, keys: params[:kind].to_s)) unless kind
    return respond_error(l(:error_gk_people_relation_project)) if params[:project_id].present? && project.nil?

    # The place people.relation_new decides (off keeps no reason)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.relation_new', params[:reason]) : nil
    return respond_error(check.error) if check && !check.ok

    reason = check ? check.text : params[:reason].to_s.strip.presence
    rel = GkPeopleOrganizationKind.new(organization: @org, kind: kind, project: project, reason: reason,
                                     valid_from: date(params[:valid_from]) || User.current.today, valid_to: date(params[:valid_to]),
                                     created_at: Time.current, created_by_id: User.current.id)
    return respond_error(rel.errors.full_messages.join(', ')) unless rel.save

    GkPeople.write_on(@org, 'organization_relation_added', relation_details(rel), reason: rel.reason)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_organization_path(@org, anchor: 'gk-people-relations') }
      format.json { render json: { relation: self.class.relation_json(rel) }, status: :created }
    end
  end

  # The relation ends on a day (today unless said), with a reason; one that never came into force goes
  def end_relation
    rel = @org.kind_links.visible.find_by(id: params[:relation_id])
    return render_404 unless rel
    # The place people.relation_end decides; without records the reason is required as before
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.relation_end', params[:reason]) : nil
    return respond_error(check.error) if check && !check.ok
    return respond_error(l(:error_gk_people_reason_required)) if check.nil? && params[:reason].to_s.strip.empty?

    reason = check ? check.text : params[:reason].to_s.strip

    on = date(params[:valid_to]) || User.current.today
    return respond_error(l(:error_gk_people_relation_ended)) if rel.valid_to && rel.valid_to <= on

    rel.valid_to = rel.valid_from && on < rel.valid_from ? rel.valid_from : on
    return respond_error(rel.errors.full_messages.join(', ')) unless rel.save

    GkPeople.write_on(@org, 'organization_relation_ended', relation_details(rel), reason: reason)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_people_organization_path(@org, anchor: 'gk-people-relations') }
      format.json { render json: { relation: self.class.relation_json(rel) } }
    end
  end

  def self.relation_json(r)
    { id: r.id, kind: r.kind.key, kind_name: r.kind.name, project_id: r.project_id, project: r.project&.identifier,
      valid_from: r.valid_from, valid_to: r.valid_to, reason: r.reason, state: r.state.to_s }
  end

  private

  def find_org
    @org = find_or_404(GkPeopleOrganization)
  end

  def relation_details(r) = { kind: r.kind.key, project: r.project&.identifier, valid_from: r.valid_from&.to_s, valid_to: r.valid_to&.to_s }.compact

  def respond_error(msg)
    respond_to do |format|
      format.html { flash[:error] = msg; redirect_to gk_people_organization_path(@org, anchor: 'gk-people-relations') }
      format.json { render json: { errors: [msg] }, status: 422 }
    end
  end
end
