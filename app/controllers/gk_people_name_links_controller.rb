# frozen_string_literal: true

# The chat program behind names on a page (GET /gk_people/name_links?ids=1,2&title=&url=): per account the link
# with the page's title and address, the program's name and icon (GkPeople::NameLinks). Only an address on this
# site is carried along.
class GkPeopleNameLinksController < ApplicationController
  # the pages and the API are closed without GK GUI Stuff (GkPeople::Gate, extensions/gk_people/gate.rb): core's 404
  include GkPeople::Gate::Controller
  before_action :require_login

  def index
    url = params[:url].to_s
    url = '' unless url.start_with?("#{request.base_url}/")
    links = GkPeople::NameLinks.for(User.current, params[:ids].to_s.split(','), title: params[:title].to_s.truncate(200), url: url)
    render json: { users: links.transform_keys(&:to_s) }
  end
end
