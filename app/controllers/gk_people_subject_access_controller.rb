# frozen_string_literal: true

# Registerutdrag: everything the instance holds about a person, for the person herself (from Mitt konto) or made by
# an administrator for her. Made on each request and never kept; that it was made is an event on the person.
# Correction and objection go as an issue, never by editing the extract.
class GkPeopleSubjectAccessController < GkPeopleBaseController
  before_action :require_login

  # The person's own: the person her account belongs to
  def mine
    @person = GkPeople.person_for(User.current)
    return render(:no_person) unless @person

    show_extract
  end

  def show
    @person = GkPeoplePerson.find_by(id: params[:id])
    return render_404 unless @person
    return deny_access unless GkPeople::SubjectAccess.allowed?(@person)

    show_extract
  end

  private

  def show_extract
    @parts = GkPeople::SubjectAccess.extract(@person)
    # The content goes only to the person herself (H63; Privat before Se som): an administrator who makes the extract
    # for her sees the tables, why they are kept and how many rows, never the rows, and hands the person her own copy
    @content = @person.user_id.present? && @person.user_id == User.current.id
    @made_at = Time.current
    GkPeople::SubjectAccess.log!(@person, @parts)
    render :show
  end
end
