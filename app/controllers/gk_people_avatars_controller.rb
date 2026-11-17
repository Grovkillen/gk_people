# frozen_string_literal: true

# Pictures of users. show and folder give an account's own picture or its organization folder's, one
# size, only to a signed-in user who may see people and the account; 404 with the function people.avatars off, for
# an account without a picture, or one the viewer may not see. edit and update (one form, one Save) and remove change it, for one
# who may (GkPeople::Avatars.may_edit?: an administrator, Hantera bilder på personer for any account, Byta egen bild
# for one's own). The picture comes as the small part chosen in the browser (gui_stuff image_crop, a PNG data URL)
# or, without it, as the file, whose middle is taken; it is made again on the server without metadata and never
# kept. A folder picture is never changed here: only the part of it that is used (region), whose place is kept.
class GkPeopleAvatarsController < GkPeopleBaseController
  feature_pages GkPeople::Avatars::FEATURE
  helper :avatars
  # Signed in: may see people (require_view). Not signed in: only while pictures are not hidden from those
  before_action :require_picture_viewer, only: %i[show folder]
  before_action :find_principal
  before_action :require_edit, only: %i[edit update remove original]

  def show
    return render_404 unless GkPeople::Avatars.visible?(@principal)

    row = GkPeopleAvatar.find_by(user_id: @principal.id, size: params[:size].to_i)
    return render_404 unless row

    send_picture(row)
  end

  # The picture from the organization's folder, one size, made now if the file is new or changed (GkPeople::AvatarFolder)
  def folder
    return render_404 unless GkPeople::Avatars.visible?(@principal) && GkPeople::Avatars::SIZES.include?(params[:size].to_i)

    file = GkPeople::AvatarFolder.shown_file_for(@principal)
    return render_404 unless file

    send_picture(GkPeople::AvatarFolder.picture(@principal, file, params[:size].to_i))
  rescue GkPeople::Avatars::Error => e
    logger&.warn("[gk_people] folder picture for #{@principal.id}: #{e.message}")
    render_404
  end

  def edit
    @own = GkPeople::Avatars.any?(@principal)
    @icon = GkPeople::AvatarIcon.icon_for(@principal)
    @file = GkPeople::AvatarFolder.file_for(@principal)
    @region = GkPeopleAvatarRegion.find_by(user_id: @principal.id)
    @may_hide_folder = @file && may_hide_folder?
  end

  # One form with one Save, as Redmine's own pages: the icon, a new own picture, hiding the organization's picture and
  # the part of the folder's picture, each taken only where it was changed. The first error stops and is said.
  def update
    error = save_icon || save_picture || save_hide_folder || save_region
    if error
      flash[:error] = l(error)
    else
      flash[:notice] = l(:notice_successful_update)
    end
    redirect_to gk_people_avatar_edit_path(user_id: @principal.id)
  end

  def remove
    GkPeople::Avatars.event(@principal, 'account_picture_removed') if GkPeople::Avatars.remove(@principal)
    flash[:notice] = l(:notice_gk_people_avatar_removed)
    redirect_to gk_people_avatar_edit_path(user_id: @principal.id)
  end

  # The folder's file as it is, only to one who may change the account's picture, to choose the part in the browser
  def original
    file = GkPeople::AvatarFolder.file_for(@principal)
    return render_404 unless file

    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Cache-Control'] = 'private, no-store'
    send_file file.path, type: "image/#{file.coder}", disposition: 'inline'
  end

  private

  def find_principal
    @principal = Principal.find_by(id: params[:user_id].to_i)
    render_404 unless @principal
  end

  def require_picture_viewer
    return if !User.current.logged? && !GkPeople::Outward.hide_pictures_for_anonymous?

    require_view
  end

  def require_edit
    return if GkPeople::Avatars.may_edit?(@principal)

    User.current.logged? ? deny_access : require_login
  end

  # The person's choice to hide the organization's picture, where the organization allows it
  def may_hide_folder?
    org = GkPeople::AvatarFolder.organization_for(GkPeople::AvatarFolder.person_for(@principal))
    @principal.is_a?(User) && org&.avatar_hide_allowed
  end

  # The icon from the icon library (step 5), when the field was changed; an empty name clears it
  def save_icon
    return nil unless params.key?(:icon) && GkPeople::AvatarIcon.library?

    name = params[:icon].to_s.strip
    return nil if name == GkPeople::AvatarIcon.icon_for(@principal).to_s

    if GkPeople::AvatarIcon.set(@principal, name)
      GkPeople::Avatars.event(@principal, 'account_icon_set', { icon: name.presence })
      nil
    elsif name.present?
      :error_gk_people_avatar_icon_unknown
    end
  end

  # A new own picture: the small part from the browser, or without it the file, whose middle is taken
  def save_picture
    bytes = GkPeople::Avatars.from_data_url(params[:picture_data]) if params[:picture_data].present?
    bytes ||= params[:picture_file].read(GkPeople::Avatars::MAX_BYTES + 1) if params[:picture_file].respond_to?(:read)
    return nil if bytes.nil? && params[:picture_data].blank?

    GkPeople::Avatars.store(@principal, bytes.to_s, by: User.current)
    GkPeople::Avatars.event(@principal, 'account_picture_set', { by_crop: params[:picture_data].present? })
    nil
  rescue GkPeople::Avatars::Error => e
    logger&.info("[gk_people] picture not taken for #{@principal.id}: #{e.message}")
    :error_gk_people_avatar_not_taken
  end

  def save_hide_folder
    return nil unless params.key?(:hide) && may_hide_folder?

    pref = @principal.pref
    want = params[:hide].to_s == '1' ? '1' : '0'
    return nil if pref[:gk_people_hide_folder_picture].to_s == want || (want == '0' && pref[:gk_people_hide_folder_picture].blank?)

    pref.gk_people_hide_folder_picture = want
    pref.save
    nil
  end

  # The part of the folder's picture that is used, when it was moved or Use the middle was ticked; the middle forgets it
  def save_region
    return nil unless GkPeople::AvatarFolder.file_for(@principal)

    old = GkPeopleAvatarRegion.find_by(user_id: @principal.id)
    middle = params[:middle].to_s == '1'
    vals = %i[x y s].to_h { |k| [k, middle ? nil : params.dig(:region, k).presence] }
    if vals.values.all?
      v = vals.transform_values { |x| x.to_d.round(5) }
      return nil if old && old.x == v[:x] && old.y == v[:y] && old.s == v[:s]

      r = old || GkPeopleAvatarRegion.new(user_id: @principal.id)
      r.assign_attributes(x: v[:x], y: v[:y], s: v[:s], set_by_id: User.current.id)
      return :error_gk_people_avatar_not_taken unless r.save
    else
      return nil unless old && (middle || vals.values.none?)

      old.destroy
    end
    GkPeopleAvatarFile.where(user_id: @principal.id).delete_all
    GkPeople::AvatarFolder.forget!
    GkPeople::Avatars.event(@principal, 'account_picture_region_set', { middle: !vals.values.all? })
    nil
  end

  def send_picture(row)
    response.headers['X-Content-Type-Options'] = 'nosniff'
    expires_in 1.day, public: false
    return unless stale?(etag: row.checksum, last_modified: row.updated_at, public: false)

    send_data row.data, type: 'image/jpeg', disposition: 'inline', filename: "#{@principal.id}-#{row.size}.jpg"
  end
end
