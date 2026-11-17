# frozen_string_literal: true

# A person's identifiers: added on the person's page (a token is "read" into the field: the reader types it and
# Enter), and ended, never deleted (P1): an ended identifier is inactive from today and stays as history.
# REST: GET and POST /gk_people/persons/:person_id/identifiers.json, POST .../identifiers/:id/end.json.
class GkPeopleIdentifiersController < GkPeopleBaseController
  feature_pages 'people.identifiers'
  accept_api_auth :index, :create, :end_identifier
  before_action :require_view
  before_action :find_person
  before_action :require_identifiers, only: %i[create end_identifier]

  def index
    rows = @person.identifiers.includes(:scheme).to_a
    rows = rows.select { |i| i.scheme.key == params[:scheme] } if params[:scheme].present?
    render json: { identifiers: rows.map { |i| identifier_json(i) } }
  end

  def create
    p = params.require(:identifier)
    scheme = GkPeopleScheme.active.find_by(id: p[:scheme_id]) || GkPeopleScheme.active.find_by(key: p[:scheme].to_s)
    ident = @person.identifiers.build(scheme: scheme, preferred: %w[1 true].include?(p[:preferred].to_s),
                                      valid_from: p[:valid_from].presence, valid_to: p[:valid_to].presence, created_by_id: User.current.id)
    ident.raw_value = p[:value]
    ident.errors.add(:scheme, :blank) unless scheme
    if scheme && ident.save
      others_not_preferred(ident) if ident.preferred
      GkPeople.write_on(@person, 'identifier_added', GkPeople::PersonEvents.identifier(ident)) # the value masked
      respond_to do |format|
        format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_person_path(@person, anchor: 'gk-people-identifiers') }
        format.json { render json: { identifier: identifier_json(ident) }, status: :created }
      end
    else
      respond_to do |format|
        format.html { flash[:error] = ident.errors.full_messages.join(', '); redirect_to gk_people_person_path(@person, anchor: 'gk-people-identifiers') }
        format.json { render json: { errors: ident.errors.full_messages }, status: 422 }
      end
    end
  end

  def end_identifier
    ident = @person.identifiers.find_by(id: params[:id])
    return render_404 unless ident

    # The place people.identifier_end decides (a reason comes by REST only; off keeps none)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.identifier_end', params[:reason]) : nil
    if check && !check.ok && ident.active
      respond_to do |format|
        format.html { flash[:error] = check.error; redirect_to gk_people_person_path(@person, anchor: 'gk-people-identifiers') }
        format.json { render json: { errors: [check.error] }, status: 422 }
      end
      return
    end

    if ident.active
      ident.update_columns(active: false, valid_to: [User.current.today,ident.valid_from].compact.max, updated_at: Time.current)
      GkPeople.write_on(@person, 'identifier_removed', GkPeople::PersonEvents.identifier(ident), reason: check ? check.text : params[:reason].presence)
    end
    respond_to do |format|
      format.html { redirect_to gk_people_person_path(@person, anchor: 'gk-people-identifiers') }
      format.json { head :no_content }
    end
  end

  private

  def find_person
    @person = find_or_404(GkPeoplePerson, :gk_people_person_id)
  end

  def require_identifiers
    deny_access unless GkPeople::Access.identifiers? || GkPeople::Access.manage?
  end

  # One preferred channel per scheme
  def others_not_preferred(ident)
    @person.identifiers.where(scheme_id: ident.scheme_id).where.not(id: ident.id).update_all(preferred: false)
  end
end
