# frozen_string_literal: true

# sync (GkPeople::Sync): POST /gk_people/sync/{organizations,persons,groups}.json from the integration account
# (permission gk_people_sync), and the log of every call: GET /gk_people/sync_log[.json] (Administration > Synk,
# for administrators and the integration account). REST only, as core: off when core's REST API is off.
class GkPeopleSyncController < GkPeopleBaseController
  feature_pages 'people.sync'
  accept_api_auth :create, :index, :show
  before_action :require_login
  before_action :require_sync, only: %i[create]
  before_action :require_log, only: %i[index show]
  layout 'admin'
  menu_item :gk_people_sync_log

  # { "source": "monitor", "persons": [ { "external_id": "K1001", ... }, ... ] }
  def create
    resource = params[:resource].to_s
    body = payload
    src = body['source'].to_s
    posts = body[resource]
    if (refused = GkPeople::Sync.refuse(resource, src, posts))
      return render json: { errors: [refused[1]] }, status: refused[0]
    end

    log = GkPeople::Sync.run(resource, src, posts)
    render json: log_json(log, full: true), status: :ok
  end

  def index
    scope = GkPeopleSyncLog.includes(:user)
    scope = scope.where(source: params[:source].to_s) if params[:source].present?
    scope = scope.where(resource: params[:resource]) if GkPeople::Sync::RESOURCES.include?(params[:resource])
    # through the model's attribute, so the bounds go to the database with their offset (started_at has its zone)
    scope = scope.where(started_at: day_start(params[:from].to_date)..) if params[:from].present? && (params[:from].to_date rescue nil)
    scope = scope.where(started_at: ..day_end(params[:to].to_date)) if params[:to].present? && (params[:to].to_date rescue nil)
    @count = scope.count
    @pages = Paginator.new(@count, per_page, params['page'])
    @logs = scope.sorted.offset(@pages.offset).limit(@pages.per_page).to_a
    respond_to do |format|
      format.html
      format.json { render json: { sync_log: @logs.map { |l| log_json(l) }, total_count: @count, offset: @pages.offset, limit: @pages.per_page } }
    end
  end

  def show
    @log = GkPeopleSyncLog.find_by(id: params[:id])
    return render_404 unless @log

    respond_to do |format|
      format.html
      format.json { render json: { sync_log: log_json(@log, full: true) } }
    end
  end

  private

  def payload
    raw = request.raw_post.to_s
    return params.to_unsafe_h.except('controller', 'action', 'format', 'resource') if raw.empty? || !request.content_mime_type&.json?

    JSON.parse(raw)
  rescue JSON::ParserError
    {}
  end

  def require_sync
    return if GkPeople::Sync.allowed?

    api_request? ? render_403 : deny_access
  end

  def require_log
    return if User.current.admin? || GkPeople::Sync.allowed?

    deny_access
  end

  # The account that made the call in records' API form (api_account): one the asker may not see is
  # { id: null, hidden: true }
  def log_json(l, full: false)
    h = { id: l.id, source: l.source, resource: l.resource, user: l.user && api_account(l.user_id, l.user, %i[login]),
          started_at: l.started_at, finished_at: l.finished_at, received: l.received, created: l.created, updated: l.updated,
          unchanged: l.unchanged, rejected: l.rejected }
    h[:errors] = l.errors_list if full
    h
  end
end
