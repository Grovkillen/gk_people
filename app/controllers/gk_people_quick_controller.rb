# frozen_string_literal: true

# Snabbkontakter: the line saved from a meeting or an organization's page (JSON for the box's script, a plain post
# without it), the preview while typing, a part moved afterwards, Att komplettera with Klar, Slå ihop and Det är
# olika, the page for merging with any other, and the list of roles and departments under Administration. No new
# permission: Quick.context and Access decide.
class GkPeopleQuickController < GkPeopleBaseController
  before_action :require_ready
  before_action :require_on
  before_action :find_context, only: %i[create preview]
  before_action :require_view, only: %i[index merge_page]
  before_action :find_record, only: %i[move done merge_page merge different]
  before_action :require_manage, only: %i[done merge different]
  before_action :require_admin, only: %i[words update_words]

  # One line or several (pasted); each its own post. JSON: { rows: [...] } with each line's result in order
  def create
    text = params[:lines].presence || params[:line].to_s
    results = GkPeople::Quick.save_text!(text, @ctx)
    respond_to do |format|
      format.json { render json: { rows: results.map { |r| result_json(r) } } }
      format.html do
        ok = results.select(&:ok)
        bad = results.reject(&:ok)
        flash[:notice] = l(:notice_gk_people_quick_saved, count: ok.size) if ok.any?
        flash[:error] = bad.map { |r| "#{r.line}: #{r.errors.join(', ')}" }.join(' ') if bad.any?
        redirect_back_or_default(back_path)
      end
    end
  end

  def preview
    render json: GkPeople::Quick.preview(params[:line].to_s)
  end

  def move
    return deny_access unless GkPeople::Quick.may_move?(@rec)

    error = GkPeople::Quick.move_part!(@rec, params[:part].to_i, params[:to].to_s)
    @rec.reload
    respond_to do |format|
      format.json { error ? render(json: { errors: [error] }, status: 422) : render(json: { row: row_json(@rec) }) }
      format.html { error ? flash[:error] = error : flash[:notice] = l(:notice_successful_update); redirect_back_or_default(record_path(@rec)) }
    end
  end

  # Att komplettera, with the filters mine, project and organization
  def index
    @mine = params[:mine] == '1'
    @project = params[:project_id].present? ? Project.visible.find_by(id: params[:project_id].to_i) : nil
    @organization = params[:organization_id].present? ? GkPeopleOrganization.find_by(id: params[:organization_id].to_i) : nil
    persons, orgs = GkPeople::Quick.to_complete(mine: @mine, project: @project, organization: @organization)
    @persons = persons.limit(200).to_a
    @orgs = orgs.limit(200).to_a
    @projects = Project.visible.active.sorted.to_a
  end

  def done
    error = GkPeople::Quick.raise!(@rec)
    error ? flash[:error] = error : flash[:notice] = l(:notice_gk_people_quick_done)
    redirect_back_or_default(record_path(@rec))
  end

  # Slå ihop med...: the suggestions and a search among all of the same sort
  def merge_page
    @suggestions = GkPeople::Quick.suggestions(@rec)
    @q = params[:q].to_s.strip
    return if @q.length < 2

    scope = @rec.is_a?(GkPeoplePerson) ? GkPeoplePerson.not_merged.active.search(@q).sorted : GkPeopleOrganization.not_merged.active.search(@q).sorted
    @found = scope.where.not(id: @rec.id).limit(20).to_a
  end

  def merge
    other = GkPeople::Quick.find(@type, params[:other_id])
    error = GkPeople::Quick.merge!(@rec, other)
    if error
      flash[:error] = error
      redirect_back_or_default(gk_people_quick_merge_path(@type, @rec.id))
    else
      flash[:notice] = l(:notice_gk_people_quick_merged, name: other.name)
      redirect_to record_path(other)
    end
  end

  def different
    other = GkPeople::Quick.find(@type, params[:other_id])
    error = GkPeople::Quick.mark_different!(@rec, other)
    error ? flash[:error] = error : flash[:notice] = l(:notice_gk_people_quick_different)
    redirect_back_or_default(gk_people_to_complete_path)
  end

  # Administration > Roller och avdelningar: a table with a row per word and a column per content language; a row
  # taken away makes its word inactive, a word written again is active again, the order as shown
  def words
    GkPeopleQuickWord.ensure_seeded!
    @languages = GkPeopleQuickWord.languages
    @words = GkPeopleQuickWord.active.sorted.to_a
  end

  # words[N][id] (empty for a new row) and words[N][texts][<lang>]; rows without any text are left out
  def update_words
    raw = params[:words]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    rows = (raw.is_a?(Hash) ? raw.sort_by { |k, _v| k.to_s.to_i }.map(&:last) : Array(raw)).grep(Hash).first(500).map do |r|
      texts = r['texts'] || r[:texts]
      { id: (r['id'] || r[:id]).to_s, texts: texts.is_a?(Hash) ? texts.to_h.transform_keys(&:to_s) : {} }
    end
    GkPeopleQuickWord.save_table!(rows, user: User.current)
    flash[:notice] = l(:notice_successful_update)
    redirect_to gk_people_quick_words_path
  rescue ActiveRecord::RecordInvalid => e
    flash[:error] = e.record.errors.full_messages.join(', ')
    redirect_to gk_people_quick_words_path
  end

  private

  def require_ready
    render_404 unless GkPeople::Quick.ready?
  end

  PAGES = %w[index merge_page words].freeze

  def require_on
    return if GkPeople::Quick.on?
    return render_404 if PAGES.include?(action_name)

    msg = GkPeople::Quick.off_error
    respond_to do |format|
      format.json { render json: { errors: [msg] }, status: 403 }
      format.any { render_error(message: msg, status: 403) }
    end
  end

  def find_context
    @ctx = GkPeople::Quick.context(params[:context])
    return if @ctx

    User.current.logged? ? deny_access : require_login
  end

  def find_record
    @type = params[:type].to_s
    @rec = GkPeople::Quick.find(@type, params[:id])
    render_404 unless @rec
  end

  def record_path(rec) = rec.is_a?(GkPeopleOrganization) ? gk_people_organization_path(rec) : gk_people_person_path(rec)

  def back_path
    return issue_path(@ctx.issue) if @ctx&.issue
    return gk_people_organization_path(@ctx.organization) if @ctx&.organization

    gk_people_to_complete_path
  end

  def result_json(r)
    return { ok: false, line: r.line, errors: r.errors } unless r.ok

    rec = r.person || r.organization
    row_json(rec).merge(ok: true, line: r.line, org_made: r.org_made, tip: r.tip)
  end

  # What the box draws for a saved post: its name and page, its organization, its parts (with the field each went to,
  # and whether it may be moved), and its verification status in the words of its place
  def row_json(rec)
    org = rec.is_a?(GkPeoplePerson) ? rec.organization : nil
    status = defined?(GkRecords::Verification) && GkRecordsVerification.table_exists? ? GkRecords::Verification.get(rec) : nil
    status = nil if status.to_s == GkPeople::VerificationPlaces::STEPS.first
    { type: GkPeople::Quick.key_of(rec), id: rec.id, name: rec.name, url: record_path(rec), quick: GkPeople::Quick.quick?(rec),
      organization: org && { id: org.id, name: org.name, url: gk_people_organization_path(org), quick: GkPeople::Quick.quick?(org) },
      parts: GkPeople::Quick.parts_json(GkPeople::Quick.parts_of(rec)), status: status && GkPeople::VerificationPlaces.word(status, GkPeople::Quick.key_of(rec)).presence,
      movable: GkPeople::Quick.may_move?(rec), move_url: rec.is_a?(GkPeoplePerson) ? gk_people_quick_move_path('person', rec.id) : nil }
  end
end
