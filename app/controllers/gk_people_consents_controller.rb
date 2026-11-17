# frozen_string_literal: true

# A person's consents: recorded and revoked by those who may manage the registers, never deleted. REST: POST
# /gk_people/persons/:id/consents.json, PATCH.../consents/:consent_id/revoke.json; the consents are in the
# person's JSON (full).
class GkPeopleConsentsController < GkPeopleBaseController
  accept_api_auth :create, :revoke
  before_action :require_manage
  before_action :find_person

  def create
    project = params[:project_id].present? ? Project.visible.find_by(id: params[:project_id]) : nil
    return respond_error(l(:error_gk_people_relation_project)) if params[:project_id].present? && project.nil?

    c = GkPeopleConsent.new(person: @person, purpose: params[:purpose].to_s.strip, project: project,
                          given_on: date(params[:given_on]) || User.current.today, valid_to: date(params[:valid_to]),
                          recorded_by_id: User.current.id)
    return respond_error(c.errors.full_messages.join(', ')) unless c.save

    GkPeople.write_on(@person, 'person_consent_given', { purpose: c.purpose, project: project&.identifier, given_on: c.given_on.to_s,
                                                          valid_to: c.valid_to&.to_s }.compact)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_person_path(@person, anchor: 'gk-people-consents') }
      format.json { render json: { consent: self.class.consent_json(c) }, status: :created }
    end
  end

  # Revoked on a day (today unless said), with the person's reason if she gave one; the row stays
  def revoke
    c = @person.consents.find_by(id: params[:consent_id])
    return render_404 unless c
    return respond_error(l(:error_gk_people_consent_revoked)) if c.revoked_on

    # The place people.consent_revoke decides (off keeps no reason)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.consent_revoke', params[:reason]) : nil
    return respond_error(check.error) if check && !check.ok

    c.revoked_on = date(params[:revoked_on]) || User.current.today
    c.revoke_reason = check ? check.text : params[:reason].to_s.strip.presence
    c.revoked_by_id = User.current.id
    return respond_error(c.errors.full_messages.join(', ')) unless c.save

    GkPeople.write_on(@person, 'person_consent_revoked', { purpose: c.purpose, revoked_on: c.revoked_on.to_s }, reason: c.revoke_reason)
    respond_to do |format|
      format.html { flash[:notice] = l(:notice_gk_people_consent_revoked); redirect_to gk_people_person_path(@person, anchor: 'gk-people-consents') }
      format.json { render json: { consent: self.class.consent_json(c) } }
    end
  end

  def self.consent_json(c)
    { id: c.id, purpose: c.purpose, project_id: c.project_id, given_on: c.given_on, valid_to: c.valid_to, revoked_on: c.revoked_on,
      revoke_reason: c.revoke_reason, state: c.state.to_s }
  end

  private

  def find_person
    @person = find_or_404(GkPeoplePerson)
  end

  def respond_error(msg)
    respond_to do |format|
      format.html { flash[:error] = msg; redirect_to gk_people_person_path(@person, anchor: 'gk-people-consents') }
      format.json { render json: { errors: [msg] }, status: 422 }
    end
  end
end
