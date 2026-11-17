# frozen_string_literal: true

# Stega upp (elevation): the step-up form and stepping down, for an administrator's own account,
# and Administration > Upphöjningar, the trace of every elevation and what was changed under it (for those stepped up).
# The form opens in gui_stuff's surface over the page when gui_stuff is there; the page itself is the fallback without
# script, and the barrier when a page that needs admin was asked for. The surface fetches the form as a fragment
# (fragment=1) and sends it as JSON.
class GkPeopleElevationsController < GkPeopleBaseController
  before_action :require_login
  before_action :require_real_admin, only: %i[new create step_down]
  before_action :require_admin, only: %i[index show]
  layout :elevation_layout

  def new
    return redirect_back_or_default(home_path) if GkPeople::Elevation.elevated? && !fragment?

    prepare_form
    render(partial: 'form', locals: form_locals) if fragment?
  end

  def create
    prepare_form
    if GkPeople::Elevation.elevated?
      return respond_stepped_up
    end
    return respond_form(422) unless GkPeople::Elevation.may_step_up?

    # after five wrong passwords in a row: wait before the next try (the password is not looked at meanwhile)
    wait = GkPeople::Elevation.wait_seconds(User.current)
    if wait.positive?
      GkPeople::Elevation.refuse_waiting!(User.current, wait)
      @error = l(:error_gk_people_elevation_wait, seconds: wait)
      return respond_form(429)
    end

    # The place people.elevation decides (off keeps no reason); the password is not looked at while the reason is
    # missing
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.elevation', params[:reason]) : nil
    if check && !check.ok
      @error = check.error
      return respond_form(422)
    end

    if GkPeople::Elevation.step_up!(self, params[:password], check ? check.text : params[:reason])
      flash[:notice] = l(:notice_gk_people_stepped_up, until: format_time(GkPeople::Elevation.current.expires_at, false))
      respond_stepped_up
    else
      wait = GkPeople::Elevation.wait_seconds(User.current)
      @error = wait.positive? ? "#{l(:notice_account_wrong_password)} #{l(:error_gk_people_elevation_wait, seconds: wait)}" : l(:notice_account_wrong_password)
      @reasons = GkPeople::Elevation.earlier_reasons(User.current)
      respond_form(422)
    end
  end

  def step_down
    GkPeople::Elevation.step_down!(self)
    flash[:notice] = l(:notice_gk_people_stepped_down)
    redirect_to home_path
  end

  def index
    scope = GkPeopleElevation.includes(:user, :person)
    scope = scope.where(user_id: params[:user_id].to_i) if params[:user_id].present?
    @count = scope.count
    @pages = Paginator.new(@count, per_page_option, params['page'])
    @elevations = scope.sorted.offset(@pages.offset).limit(@pages.per_page).to_a
    @action_counts = GkPeopleElevationAction.where(elevation_id: @elevations.map(&:id)).group(:elevation_id).count
  end

  def show
    @elevation = GkPeopleElevation.find_by(id: params[:id])
    return render_404 unless @elevation

    @actions = @elevation.actions.to_a
    @see_as = GkPeople::SeeAs.table? ? GkPeopleSeeAs.where(elevation_id: @elevation.id).includes(:target_user, :target_group, :role, :project).order(:started_at).to_a : []
  end

  private

  def fragment? = params[:fragment].to_s == '1'
  def json? = request.format.json? || request.xhr?

  # Administration's layout for the trace, the ordinary one for stepping up (layout with only: would leave the other
  # actions without any)
  def elevation_layout = %w[index show].include?(action_name) ? 'admin' : 'base'

  def prepare_form
    @lacks_person = GkPeople::Elevation.lacks_person?
    @inactive = !GkPeople::Elevation.governs?(User.current)
    @reasons = GkPeople::Elevation.earlier_reasons(User.current)
  end

  def form_locals = { reasons: @reasons, inactive: @inactive, lacks_person: @lacks_person, error: @error }

  # Where to go after stepping up: the page asked for (checked like core's back_url), else Administration
  def after_url
    url = params[:back_url].present? ? validate_back_url(params[:back_url].to_s) : nil
    url || admin_path
  end

  def respond_stepped_up
    if json?
      render json: { ok: true, redirect: after_url }
    else
      redirect_to after_url
    end
  end

  def respond_form(status)
    if json?
      render json: { ok: false, html: render_to_string(partial: 'form', formats: [:html], locals: form_locals) }, status: status
    else
      flash.now[:error] = @error if @error
      render :new, status: status
    end
  end

  def require_real_admin
    render_403 unless GkPeople::Elevation.real_admin?(User.current)
  end
end
