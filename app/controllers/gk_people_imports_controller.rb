# frozen_string_literal: true

# Importera: organizations or persons from a CSV file in two steps, the preview and the run (GkPeople::Import). For
# those who may change the registers (gk_people_manage). The same through REST: POST /gk_people/imports.json { import:
# { resource, source_label, source_on, mode, separator, encoding, content (the CSV text), mapping ({ field => heading
# or column number }, optional) } } the preview PATCH /gk_people/imports/:id.json { import: { mapping, mode } } a new
# preview POST /gk_people/imports/:id/run.json the run, with counts
# Company data (a .jsonl file from Get-Foretagsdata.ps1): an administrator only; the upload, the municipalities
# chosen (PATCH { import: { selection: [codes], sole_traders } }) and the run, by GkPeople::CompanyData.

class GkPeopleImportsController < GkPeopleBaseController
  accept_api_auth :index, :show, :create, :update, :run
  before_action :require_view
  before_action :require_manage
  before_action :find_import, only: %i[show update run discard]
  # company data is read by an administrator only, from the upload to the run
  before_action :company_data_admin, only: %i[show update run discard]

  def index
    @imports = GkPeopleImport.sorted.includes(:user).limit(50).to_a
    @imports.reject!(&:company?) unless GkPeople::CompanyData.allowed?
    respond_to do |format|
      format.html
      format.json { render json: { imports: @imports.map { |i| import_json(i) } } }
    end
  end

  def new
    @resource = params[:resource].presence_in(GkPeople::Import::RESOURCES) || 'organizations'
  end

  # The template, made from the import's own fields, named by revisions' one rule
  def template
    resource = params[:resource].to_s
    send_data GkPeople::Import.template_csv(resource), type: 'text/csv; header=present',
                                                        filename: GkPeople::Import.template_name(resource)
  end

  def create
    p = params[:import] || {}
    file = p[:file]
    return create_company(p, file) if file.respond_to?(:original_filename) && GkPeople::CompanyData.file?(file.original_filename)

    bytes = file.respond_to?(:read) ? file.read : p[:content].to_s
    @import = GkPeople::Import.start!(resource: p[:resource].to_s, bytes: bytes, source_label: p[:source_label], source_on: p[:source_on],
                                       mode: p[:mode], separator: p[:separator].presence || 'auto', encoding: p[:encoding].presence || 'auto',
                                       filename: file.respond_to?(:original_filename) ? file.original_filename : p[:filename],
                                       mapping: p[:mapping].respond_to?(:to_unsafe_h) ? p[:mapping].to_unsafe_h : p[:mapping],
                                       manifest: p[:manifest].respond_to?(:to_unsafe_h) ? p[:manifest].to_unsafe_h : p[:manifest].presence)

    respond_to do |format|
      format.html { redirect_to gk_people_import_path(@import) }
      format.json { render json: { import: import_json(@import, rows: true) }, status: :created }
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.html do
        flash.now[:error] = e.message
        @resource = p[:resource].presence_in(GkPeople::Import::RESOURCES) || 'organizations'
        render :new, status: 422
      end
      format.json { render json: { errors: [e.message] }, status: 422 }
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json { render json: { import: import_json(@import, rows: true) } }
    end
  end

  # New choices (the mapping, the mode; for company data the selection and sole traders) and a new preview
  def update
    return render_403 unless @import.preview?

    p = params[:import] || {}
    if @import.company?
      GkPeople::CompanyData.choose!(@import, codes: Array(p[:selection]), sole_traders: p[:sole_traders].to_s != '0')
      return respond_to do |format|
        format.html { redirect_to gk_people_import_path(@import) }
        format.json { render json: { import: import_json(@import.reload, rows: true) } }
      end
    end
    if p.key?(:mapping)
      m = p[:mapping].respond_to?(:to_unsafe_h) ? p[:mapping].to_unsafe_h : p[:mapping].to_h
      m = m.reject { |_, v| v.to_s.strip.empty? }
      @import.mapping = api_request? ? GkPeople::Import.explicit_mapping(@import.resource, @import.headings, m) : m.transform_values(&:to_i)
    end
    @import.mode = p[:mode] if GkPeople::Import::MODES.include?(p[:mode].to_s)
    @import.save!
    GkPeople::Import.refresh!(@import)
    respond_to do |format|
      format.html { redirect_to gk_people_import_path(@import) }
      format.json { render json: { import: import_json(@import.reload, rows: true) } }
    end
  end

  def run
    return render_403 unless @import.preview?

    counts = @import.company? ? GkPeople::CompanyData.run!(@import, user: User.current) : GkPeople::Import.run!(@import, user: User.current)
    respond_to do |format|
      format.html do
        flash[:notice] = l(:notice_gk_people_import_done, created: counts['new'], updated: counts['update'], rejected: counts['rejected'])
        redirect_to gk_people_import_path(@import)
      end
      format.json { render json: { import: import_json(@import.reload, rows: true) } }
    end
  rescue ArgumentError => e
    # The reading refused the file; the import stays in preview
    respond_to do |format|
      format.html { flash[:error] = e.message; redirect_to gk_people_import_path(@import) }
      format.json { render json: { errors: [e.message] }, status: 422 }
    end
  end


  def discard
    GkPeople::Import.discard!(@import)
    redirect_to gk_people_imports_path
  end

  private

  # Company data: the upload is read where it lies, never into memory, up to the page's limits
  def create_company(p, file)
    return deny_access unless GkPeople::CompanyData.allowed?

    manifest = p[:manifest].respond_to?(:to_unsafe_h) ? p[:manifest].to_unsafe_h : p[:manifest].presence
    @import, = GkPeople::CompanyData.start_upload!(file, manifest: manifest, source_label: p[:source_label], source_on: p[:source_on])
    respond_to do |format|
      format.html { redirect_to gk_people_import_path(@import) }
      format.json { render json: { import: import_json(@import, rows: true) }, status: :created }
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.html do
        flash.now[:error] = e.message
        @resource = 'organizations'
        render :new, status: 422
      end
      format.json { render json: { errors: [e.message] }, status: 422 }
    end
  end

  def company_data_admin
    deny_access if @import&.company? && !GkPeople::CompanyData.allowed?
  end

  def find_import
    @import = find_or_404(GkPeopleImport)
  end

  def import_json(i, rows: false)
    h = { id: i.id, resource: i.resource, state: i.state, mode: i.mode, source_label: i.source_label, source_on: i.source_on,
          filename: i.filename, headings: i.headings, mapping: i.mapping.transform_values { |c| i.headings[c] }, counts: i.counts,
          created_on: i.created_at, finished_on: i.finished_at, profile: i.profile.presence, reading_id: i.reading_id,
          unread_columns: i.unread_headings }
    h.merge!(selection: i.options['selection'], municipalities: i.options['municipalities'], file: i.options['file']) if i.company?

    h[:rows] = i.preview_rows if rows
    h
  end
end
