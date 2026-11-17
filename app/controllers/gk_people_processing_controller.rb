# frozen_string_literal: true

# Administration > Personuppgifter: the record of processing. Every table holding a person or an account, found in
# the database, with what was declared or written for it; a table without a purpose is shown as lacking one.
# Administrators only; changes are kept in gk_people_processing.
class GkPeopleProcessingController < GkPeopleBaseController
  layout 'admin'
  before_action :require_admin
  before_action :find_entry, only: %i[edit update]

  def index
    @entries = GkPeople::Processing.entries
    @missing = @entries.count(&:missing?)
  end

  def edit
    @row = @entry.row || GkPeopleProcessing.new(table_name: @entry.table)
  end

  def update
    @row = @entry.row || GkPeopleProcessing.new(table_name: @entry.table)
    p = params.require(:processing)
    @row.assign_attributes(purpose: p[:purpose].to_s.strip.presence, legal_basis: p[:legal_basis].to_s.presence,
                           retention: p[:retention].to_s.strip.presence, visible_to: p[:visible_to].to_s.strip.presence,
                           updated_by_id: User.current.id)
    if @row.save
      flash[:notice] = l(:notice_successful_update)
      redirect_to gk_people_processing_index_path(anchor: "table-#{@entry.table}")
    else
      render :edit, status: 422
    end
  end

  private

  def find_entry
    @entry = GkPeople::Processing.entry(params[:id])
    render_404 unless @entry
  end
end
