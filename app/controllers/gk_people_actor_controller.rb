# frozen_string_literal: true

# actor_records (GkPeople::Actor):
# * Vem är du? at a shared computer: the search (the persons on the account's matrix), choosing oneself, Förläng and
#   Klar;
# * the matrix of a shared account (an administrator): people groups and persons, with Redmine roles per project;
# * the records: GET /gk_people/actor_records[.json] with filters issue_id, person_id, from and to, for those with
#   gk_people_view_actor_records, and only on what they may see.
class GkPeopleActorController < GkPeopleBaseController
  accept_api_auth :index
  before_action :require_login
  before_action :require_shared, only: %i[search who choose done pin_form pin prolong]
  before_action :require_records, only: %i[index]
  before_action :require_admin, :find_shared, only: %i[matrix update_matrix]

  # [{ id, name, title }]; at most ten, two letters at least. Called without .json: core takes a .json request as
  # REST (API key, no session), and the page runs in the session
  def search
    found = GkPeople::Actor.search(params[:q], User.current)
    # mark: records' mark as HTML, drawn by records' helper, when the person's account is not seen by all ("" else)
    render json: found.map { |p| { id: p.id, name: p.name, title: p.title, mark: helpers.gk_people_mark(p.user).to_s } }
  end

  # Vem är du?
  def who
    @back_url = safe_back
    @person = GkPeople::Actor.current&.dig(:person)
    @linked = GkPeople::Actor.linked?(User.current)
  end

  # A badge (token, from a reader in keyboard mode) or a person found by name; then the PIN when the account wants it
  def choose
    user = User.current
    scheme = nil
    if params[:token].present? # rest-ok: a badge read at a shared computer, inside an account already signed in
      person, scheme = GkPeople::Identify.by_token(params[:token]) # rest-ok: the badge, not an API login
      return back_to_who(:error_gk_people_badge_unknown) unless person
      return back_to_who(:error_gk_people_badge_not_here) unless GkPeople::Actor.choosable?(person, user)

      by = 'token'
    else
      person = GkPeoplePerson.find_by(id: (params[:person_id].presence || params[:person_id_noscript]).to_i)
      unless GkPeople::Actor.choosable?(person, user)
        return back_to_who(GkPeople::Actor.linked?(user) ? :error_gk_people_actor_not_choosable : :error_gk_people_actor_no_groups)
      end

      by = 'search'
    end
    if GkPeople::SharedAccounts.require_pin?(user)
      session[PENDING] = { 'person_id' => person.id, 'by' => "#{by}_pin", 'scheme_id' => scheme&.id, 'at' => Time.now.to_i, 'back' => safe_back }
      return redirect_to(gk_people_actor_pin_path)
    end
    GkPeople::Actor.choose!(session, user, person, by: by, scheme_id: scheme&.id)
    redirect_to(safe_back || home_path)
  end

  # The PIN after the badge or the name (a start code is changed here the first time)
  def pin_form
    @person = pending_person
    return redirect_to(gk_people_actor_who_path) unless @person
  end

  def pin
    person = pending_person
    return redirect_to(gk_people_actor_who_path) unless person

    case GkPeople::Pin.check(person, params[:pin].to_s)
    when :ok
      if GkPeople::Pin.must_change?(person)
        fresh = params[:new_pin].to_s
        return back_to_pin(:error_gk_people_pin_format) unless GkPeople::Pin.valid_format?(fresh)
        return back_to_pin(:error_gk_people_pin_again) unless fresh == params[:new_pin_again].to_s
        return back_to_pin(:error_gk_people_pin_same) if fresh == params[:pin].to_s

        GkPeople::Pin.set!(person, fresh, by: 'self')
      end
      p = session.delete(PENDING)
      GkPeople::Actor.choose!(session, User.current, person, by: p['by'], scheme_id: p['scheme_id'])
      redirect_to(p['back'].presence || home_path)
    when :wrong then back_to_pin(:error_gk_people_pin_wrong)
    when :locked
      session.delete(PENDING)
      back_to_who(:error_gk_people_pin_locked)
    else
      session.delete(PENDING)
      back_to_who(person.user_id ? :error_gk_people_pin_none_own : :error_gk_people_pin_none)
    end
  end

  # Förläng (from the warning a minute before the choice runs out): held as long again without a new PIN when the
  # setting allows it; otherwise, or when the choice has already run out, the answer says to open Vem är du?
  def prolong
    user = User.current
    if GkPeople::Actor.prolong? && GkPeople::Actor.session_given(session, user)
      GkPeople::Actor.touch!(session)
      render json: { ok: true, seconds: GkPeople::Actor.seconds_left(session, user) }
    else
      render json: { ok: false, who: gk_people_actor_who_path(back_url: safe_back) }
    end
  end

  # Klar: the next one says who she is
  def done
    GkPeople::Actor.done!(session)
    redirect_to gk_people_actor_who_path
  end

  def matrix
    @projects = @account.memberships.map(&:project).compact.uniq.sort_by { |p| p.name.downcase }
    @roles = Role.givable.sorted.to_a
    @rows = GkPeople::Actor.rows(@account).to_a.group_by { |r| [r.principal_type, r.principal_id, r.project_id] }
    @groups = GkPeopleGroup.active.sorted.to_a
    @persons = GkPeoplePerson.active.where(kind: 'internal').sorted.to_a
    render layout: 'admin'
  end

  # cells[] = "type:principal:project:role" for every ticked cell; a new row: new_principal ("group:3"), new_project,
  # new_roles[]
  def update_matrix
    want = Array(params[:cells]).map { |c| c.to_s.split(':') }.select { |a| a.size == 4 }
    t, pid = params[:new_principal].to_s.split(':', 2)
    if %w[group person].include?(t) && pid.to_i.positive? && params[:new_project].to_i.positive?
      Array(params[:new_roles]).each { |rid| want << [t, pid, params[:new_project], rid] }
    end
    allowed = @account.memberships.map(&:project_id).uniq
    want = want.select { |_, _, prj, rid| allowed.include?(prj.to_i) && Role.givable.exists?(id: rid.to_i) }
    GkPeople::Actor.set_matrix!(@account, want)
    GkPeople::SharedAccounts.set_require_pin!(@account, params[:require_pin].to_s == '1') if GkPeople::SharedAccounts.ready?
    flash[:notice] = l(:notice_successful_update)
    redirect_to gk_people_shared_account_path(@account.id)
  end

  def index
    scope = GkPeopleActorRecord.visible.includes(:person, :user, :issue, :project)
    scope = scope.where(issue_id: params[:issue_id].to_i) if params[:issue_id].present?
    # person_id only for one who may see the person register: for anyone else the filter is ignored, so the answer is
    # the same whether the id has records, has none or is no person at all
    scope = scope.where(person_id: params[:person_id].to_i) if params[:person_id].present? && gk_people_view?
    # through the model's attribute, so the bounds go to the database with their offset (captured_at has its zone)
    scope = scope.where(captured_at: day_start(params[:from].to_date)..) if params[:from].present? && (params[:from].to_date rescue nil)
    scope = scope.where(captured_at: ..day_end(params[:to].to_date)) if params[:to].present? && (params[:to].to_date rescue nil)
    @count = scope.count
    @pages = Paginator.new(@count, per_page, params['page'])
    @records = scope.sorted.offset(@pages.offset).limit(@pages.per_page).to_a
    respond_to do |format|
      format.html
      format.json do
        render json: { actor_records: @records.map { |r| record_json(r) }, total_count: @count, offset: @pages.offset, limit: @pages.per_page }
      end
    end
  end

  private

  PENDING = :gk_people_actor_pin_pending

  # The person waiting for her PIN (two minutes, at this account)
  def pending_person
    p = session[PENDING]
    return nil unless p.is_a?(Hash) && Time.now.to_i - p['at'].to_i < 120

    person = GkPeoplePerson.find_by(id: p['person_id'].to_i)
    GkPeople::Actor.choosable?(person, User.current) ? person : nil
  end

  def back_to_who(key)
    flash[:error] = l(key)
    redirect_to(gk_people_actor_who_path(back_url: safe_back))
  end

  def back_to_pin(key)
    flash[:error] = l(key)
    redirect_to(gk_people_actor_pin_path)
  end

  # The page to go back to: core's validate_back_url decides, then never Vem är du? or its PIN (they would ask again)
  def safe_back
    GkPeople::BackUrl.pick(validate_back_url(params[:back_url].to_s), not_under: File.dirname(gk_people_actor_who_path))
  end

  def require_shared
    return if GkPeople::Actor.required?

    request.get? && action_name == 'who' ? redirect_to(home_path) : render_403
  end

  def require_records
    deny_access unless GkPeople::Actor.ready? && GkPeople::Actor.may_view_records?
  end

  def find_shared
    @account = User.where(type: 'User').find_by(id: params[:user_id].to_i)
    return render_404 unless @account
    return render_error(message: l(:text_gk_people_actor_not_shared, account: @account.name), status: 422) unless GkPeople::Actor.shared?(@account)
  end

  # May the asker see the person register (GkPeople::Access.view?); asked once per request
  def gk_people_view?
    @gk_people_view = GkPeople::Access.view? if @gk_people_view.nil?
    @gk_people_view
  end
  helper_method :gk_people_view?

  # The account in records' API form (api_account): one the asker may not see is { id: null, hidden: true }. The
  # person in the same form: her id and name only for one who may see the person register (GkPeople::Access.view?, the
  # test the register kind:person uses in records), otherwise { id: null, hidden: true }
  def record_json(r)
    person = gk_people_view? ? { id: r.person_id, name: r.person&.name } : { id: nil, hidden: true }
    { id: r.id, action: r.action, issue_id: r.issue_id, journal_id: r.journal_id, time_entry_id: r.time_entry_id,
      project_id: r.project_id, details: r.details_hash.presence, person: person,
      user: api_account(r.user_id, r.user, %i[login name]), captured_by: r.captured_by, scheme_id: r.scheme_id,
      captured_at: r.captured_at }
  end
end
