# frozen_string_literal: true

# Roller från ansvar (role_sync): whether it is on, the deviations (roles people gave that someone removed by hand),
# every role given now, the runs, and Synka nu. For those who handle responsibilities.
class GkPeopleRoleSyncController < GkPeopleBaseController
  feature_pages 'people.responsibilities'
  before_action :require_responsibilities

  def index
    @enabled = GkPeople::RoleSync.enabled?
    @deviations = GkPeopleRoleGrant.deviating.includes(:person, :user, :project, :role, :removed_by, rule: :responsibility).order(:removed_by_hand_at).to_a
    @grants = GkPeopleRoleGrant.active.where(removed_by_hand_at: nil).includes(:person, :project, :role, rule: :responsibility)
                             .order(:project_id, :user_id).to_a
    @runs = GkPeopleRoleSyncRun.sorted.includes(:user).limit(15).to_a
  end

  def run
    r = GkPeople::RoleSync.run!(kind: 'manual')
    if r
      flash[:notice] = l(:notice_gk_people_role_sync_run, added: r.added, removed: r.removed, deviations: r.deviations)
      flash[:error] = r.errors_text if r.errors_text.present?
    else
      flash[:error] = l(:text_gk_people_role_sync_off)
    end
    redirect_to gk_people_role_sync_path
  end

  private

  def require_responsibilities
    deny_access unless GkPeople::Responsibilities.manage?
  end
end
