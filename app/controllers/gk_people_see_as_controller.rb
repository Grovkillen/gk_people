# frozen_string_literal: true

# Se som (GkPeople::SeeAs): the choice (in gui_stuff's surface over the page, the page itself without script),
# starting, stopping and the mail preview. Always runs as the administrator herself (SeeAs::FREE), so that one can
# always stop; the choice and the start need her stepped up.
class GkPeopleSeeAsController < GkPeopleBaseController
  before_action :require_login
  before_action :require_may_start, only: %i[new search create]
  layout 'base'

  def new
    load_place
    @choices = GkPeople::SeeAs.choices(@place, User.current)
    @found = params[:q].present? ? GkPeople::SeeAs.search(params[:q], User.current) : nil
    if fragment?
      render partial: 'chooser', locals: chooser_locals
    else
      render :new
    end
  end

  def search
    load_place
    @found = GkPeople::SeeAs.search(params[:q], User.current)
    render partial: 'found', locals: { found: @found, path: @path }
  end

  def create
    load_place
    args = target_args
    return respond_error(:notice_gk_people_see_as_bad_choice) unless args

    # The place people.see_as decides (off keeps no reason)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('people.see_as', params[:reason]) : nil
    return respond_error(check.error) if check && !check.ok

    r = GkPeople::SeeAs.start!(self, **args, place: @path, reason: check ? check.text : params[:reason])
    return respond_error(:notice_gk_people_see_as_bad_choice) unless r

    url = back_url_or_home
    json? ? render(json: { ok: true, redirect: url }) : redirect_to(url)
  end

  def stop
    GkPeople::SeeAs.stop!(self)
    redirect_to back_url_or_home
  end

  # The mail the one looked as would get about an issue: rendered, never delivered, in a transaction rolled back
  def mail
    r = GkPeople::SeeAs.open_for(self)
    issue = Issue.find_by(id: params[:issue_id].to_i)
    return render_404 unless r && issue

    @record = r
    @issue = issue
    ActiveRecord::Base.transaction(requires_new: true) do
      v = GkPeople::SeeAs.viewer_for(r)
      @visible = v && issue.visible?(v)
      if @visible
        mail, @would_get = GkPeople::SeeAs.mail_preview(issue, v, r)
        @subject = mail.subject
        @html = GkPeople::SeeAs.mail_html(mail)
      end
      raise ActiveRecord::Rollback
    end
    render_mail
  rescue StandardError => e
    Rails.logger.error("[gk_people] see_as mail preview failed: #{e.class}: #{e.message}")
    @error = e.message
    render_mail
  end

  private

  def fragment? = params[:fragment].to_s == '1'
  def render_mail = (fragment? || request.xhr? ? render(partial: 'mail') : render(:mail_page))
  def json? = request.format.json? || request.xhr?

  def require_may_start
    return if GkPeople::SeeAs.may_start?

    if json? || fragment?
      render partial: 'not_now', status: (json? && !fragment? ? 403 : 200)
    else
      flash[:error] = l(:notice_gk_people_see_as_step_up_first)
      redirect_to back_url_or_home
    end
  end

  # The page Se som was opened from: the path sent along, else the referer, both through core's validate_back_url
  # (another host, a backslash or a control character, the login page: refused) and never this page itself. What
  # fails, or is longer than 500 characters, gives no place, so the chooser, the search and SeeAs.start! never carry
  # an address core would refuse.
  def load_place
    @path = GkPeople::BackUrl.pick(validate_back_url((params[:path].presence || request.referer).to_s),
                                   not_path: request.path, max: 500) || ''
    @place = GkPeople::SeeAs.place_of(@path)
  end

  def chooser_locals = { choices: @choices, place: @place, path: @path, found: @found, error: nil }

  # What was chosen, checked again here: a person (an active account, not oneself or a reserve account), a group, or
  # a role in the project of the place
  def target_args
    reserve = GkPeople::Reserve.user_ids rescue []
    kind, id = params[:pick].to_s.split(':', 2)
    params[:kind] ||= kind
    params[:target_id] ||= id if %w[person group].include?(kind)
    params[:role_id] ||= id if kind == 'role'
    case params[:kind]
    when 'person'
      u = User.active.find_by(id: params[:target_id].to_i, type: 'User')
      return nil if u.nil? || u.id == User.current.id || reserve.include?(u.id)

      { kind: 'person', target_user: u, project: @place[:project] }
    when 'group'
      g = Group.givable.find_by(id: params[:target_id].to_i)
      g && { kind: 'group', target_group: g, project: @place[:project] }
    when 'role'
      role = Role.givable.find_by(id: params[:role_id].to_i)
      project = @place[:project]
      role && project && { kind: 'role', role: role, project: project }
    end
  end

  def back_url_or_home
    url = params[:back_url].present? ? validate_back_url(params[:back_url].to_s) : nil
    url || (@path.present? ? validate_back_url(@path) : nil) || home_path
  end

  def respond_error(key)
    msg = key.is_a?(String) ? key : l(key) # A message as it is (the reason check's)
    if json?
      @error = msg
      @choices = GkPeople::SeeAs.choices(@place, User.current)
      render json: { ok: false, html: render_to_string(partial: 'chooser', formats: [:html], locals: chooser_locals.merge(error: @error)) }, status: 422
    else
      flash[:error] = msg
      redirect_to back_url_or_home
    end
  end
end
