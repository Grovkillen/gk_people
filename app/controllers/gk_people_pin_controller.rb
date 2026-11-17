# frozen_string_literal: true

# A PIN (GkPeople::Pin): one's own under Mitt konto (the account's password again, then the PIN twice), or a start
# code an administrator (or one who manages identifiers, for a person without an account) sets on a person's page,
# which must be changed the first time at the computer. Never shown, never kept in clear text.
class GkPeoplePinController < GkPeopleBaseController
  feature_pages 'people.pin'
  before_action :require_login
  before_action :require_ready
  before_action :find_own, only: %i[mine update_mine]

  def mine; end

  def update_mine
    user = User.current
    return back(:error_gk_people_pin_password) if user.hashed_password.present? && !user.check_password?(params[:password].to_s)
    return back(:error_gk_people_pin_format) unless GkPeople::Pin.valid_format?(params[:pin])
    return back(:error_gk_people_pin_again) unless params[:pin].to_s == params[:pin_again].to_s

    GkPeople::Pin.set!(@person, params[:pin].to_s, by: 'self')
    flash[:notice] = l(:notice_gk_people_pin_set)
    redirect_to my_account_path
  end

  def set_for_person
    person = GkPeoplePerson.find_by(id: params[:id].to_i)
    return render_404 unless person
    return deny_access unless GkPeople::Access.identifiers?
    # A person with an account sets her own PIN; a start code on her is the administrator's
    return require_admin if person.user_id.present? && !User.current.admin?

    if GkPeople::Pin.valid_format?(params[:pin])
      GkPeople::Pin.set!(person, params[:pin].to_s, by: 'admin')
      flash[:notice] = l(:notice_gk_people_pin_start_set)
    else
      flash[:error] = l(:error_gk_people_pin_format)
    end
    redirect_to gk_people_person_path(person, anchor: 'gk-people-pin')
  end

  private

  def require_ready
    render_404 unless GkPeople::Pin.ready?
  end

  def find_own
    @person = GkPeople.person_for(User.current)
    render_404 unless @person
  end

  def back(key)
    flash[:error] = l(key)
    redirect_to gk_people_my_pin_path
  end
end
