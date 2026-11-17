# frozen_string_literal: true

# Administration, Identifierare: the schemes (data, not code). A scheme in use is switched off, never deleted, and
# its key and kind are set once (identifiers and links depend on them). REST: GET /gk_people/schemes.json for
# anyone who may see the register, writing only for administrators.
class GkPeopleSchemesController < GkPeopleBaseController
  feature_pages 'people.identifiers'
  layout 'admin'
  accept_api_auth :index, :create, :update
  before_action :require_view, only: %i[index]
  before_action :require_schemes_admin, except: %i[index]
  before_action :find_scheme, only: %i[edit update]

  def index
    @schemes = GkPeopleScheme.sorted.to_a
    @in_use = GkPeopleIdentifier.group(:scheme_id).count
    respond_to do |format|
      format.html { require_admin }
      format.json { render json: { identifier_schemes: @schemes.map { |s| scheme_json(s) } } }
    end
  end

  def new
    @scheme = GkPeopleScheme.new(kind: 'contact', active: true, position: (GkPeopleScheme.maximum(:position) || 0) + 1)
  end

  def create
    @scheme = GkPeopleScheme.new
    assign(@scheme)
    return render_errors(@scheme) unless @scheme.save

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_create); redirect_to gk_people_schemes_path }
      format.json { render json: { identifier_scheme: scheme_json(@scheme) }, status: :created }
    end
  end

  def edit; end

  def update
    assign(@scheme)
    return render_errors(@scheme) unless @scheme.save

    respond_to do |format|
      format.html { flash[:notice] = l(:notice_successful_update); redirect_to gk_people_schemes_path }
      format.json { render json: { identifier_scheme: scheme_json(@scheme) } }
    end
  end

  private

  # Administrators; a token (OAuth) needs gk_people_api_schemes or :admin. Without gk_compat core's require_admin.
  def require_schemes_admin
    return false unless require_login
    return true if gk_compat_shim?(:admin_allows?) ? ::GkCompat.call(:admin_allows?, User.current, :gk_people_api_schemes) : User.current.admin?

    render_403
    false
  end

  # gk_compat is there and has the shim for the running series (an older gk_compat has no scope check)
  def gk_compat_shim?(name)
    defined?(::GkCompat) && ::GkCompat.respond_to?(:used) && ::GkCompat.used.shims.key?(name)
  end

  def find_scheme
    @scheme = find_or_404(GkPeopleScheme)
  end

  def assign(scheme)
    p = params.require(:scheme)
    unless scheme.persisted?
      scheme.key = p[:key].to_s.strip
      scheme.kind = p[:kind].to_s
    end
    scheme.assign_attributes(name: p[:name].to_s.strip, unique_value: %w[1 true].include?(p[:unique_value].to_s),
                             format: p[:format].to_s.strip.presence, link_template: p[:link_template].to_s.strip.presence,
                             icon: p[:icon].to_s.strip.presence, position: [p[:position].to_i, 1].max,
                             active: %w[1 true].include?(p[:active].to_s))
    scheme.show_on_list = Array(p[:show_on]).reject(&:blank?)
  end

  def render_errors(record)
    @scheme = record
    super
  end
end
