# frozen_string_literal: true

# Shared for the register pages and their REST: who may see and change (GkPeople::Access, global
# permissions or admin), and the JSON forms of a person, an organization and a scheme. Tokens never leave as more
# than their mask.
class GkPeopleBaseController < ApplicationController
  # the pages and the API are closed without GK GUI Stuff (GkPeople::Gate, extensions/gk_people/gate.rb): core's 404
  include GkPeople::Gate::Controller
  self.main_menu = false
  helper :gk_people

  # The pages of a function that is off answer 404, their REST too; asked before anything else, at each request,
  # so switching on needs no restart
  def self.feature_pages(key, **opts)
    prepend_before_action(-> { render_404 unless GkPeople.feature?(key) }, **opts)
  end

  private

  def require_view
    return if GkPeople::Access.view?

    User.current.logged? ? deny_access : require_login
  end

  def require_manage
    deny_access unless GkPeople::Access.manage?
  end

  def per_page = (api_request? ? (params[:limit].presence || 25).to_i.clamp(1, 100) : per_page_option)

  # The record of the scope with the id in params[key], or nil after a 404 (in a before_action the render stops the
  # action)
  def find_or_404(scope, key = :id)
    scope.find_by(id: params[key]).tap { |r| render_404 unless r }
  end

  # A date given as YYYY-MM-DD, or nil
  def date(v) = (Date.iso8601(v.to_s) rescue nil)

  # The start of a day as the reader counts it (her time zone, else the server's), as core's date filters do;
  # Date#beginning_of_day is in Rails' own zone, which is UTC in Redmine
  def day_start(date)
    zone = User.current.time_zone
    zone ? zone.local(date.year, date.month, date.day) : Time.local(date.year, date.month, date.day)
  end

  def day_end(date) = day_start(date).end_of_day

  def org_json(o)
    { id: o.id, name: o.name, short_name: o.short_name, kinds: o.visible_kinds.map { |k| { key: k.key, name: k.name } },
      relations: o.visible_relations.map { |r| GkPeopleRelationsController.relation_json(r) }, org_no: o.org_no, sni: o.sni,
      org_form: o.org_form, size_class: o.size_class, deregistered_on: o.deregistered_on,
      address: o.address, city: o.city, phone: o.phone, email: o.email, website: o.website, owner_langs: o.owner_langs,
      country: o.country, active: o.active,
      approval_status: o.approval_status, approval_valid_to: o.approval_valid_to,
      parent: o.parent && { id: o.parent.id, name: o.parent.name, org_no: o.parent.org_no },
      location: o.location? ? { n: o.location_n.to_f, e: o.location_e.to_f, crs: o.location_crs } : nil }
      .merge(api_account_id(:approved_by_id, o.approved_by_id, o.approved_by))
      .merge(approved_at: o.approved_at, risk_class: o.risk_class, source: o.source, external_id: o.external_id,
             info_source: o.info_source, info_source_on: o.info_source_on,
             created_on: o.created_at, updated_on: o.updated_at)
  end

  def identifier_json(i)
    { id: i.id, scheme: i.scheme.key, kind: i.scheme.kind, value: i.value, preferred: i.preferred, active: i.active,
      valid_from: i.valid_from, valid_to: i.valid_to }
  end

  def person_json(p, full: false)
    h = { id: p.id, name: p.name, display_name: p.display_name, first_name: p.first_name, last_name: p.last_name, kind: p.kind,
          organization: p.organization && { id: p.organization.id, name: p.organization.name } }
    h.merge!(api_account_id(:user_id, p.user_id, p.user))
    h.merge!(email: p.email, phone: p.phone, title: p.title, languages: p.language_list, active: p.active, source: p.source,
             external_id: p.external_id, info_source: p.info_source, info_source_on: p.info_source_on, created_on: p.created_at, updated_on: p.updated_at)
    h[:identifiers] = p.identifiers.includes(:scheme).map { |i| identifier_json(i) } if full
    h[:groups] = GkPeople::Api.groups_of(p).map { |g| { id: g.id, name: g.name } } if full
    h[:consents] = p.consents.map { |c| GkPeopleConsentsController.consent_json(c) } if full
    h
  end

  def scheme_json(s)
    { id: s.id, key: s.key, name: s.name, kind: s.kind, unique_value: s.unique_value, format: s.format, link_template: s.link_template,
      icon: s.icon, show_on: s.show_on_list, position: s.position, active: s.active }
  end

  # A Redmine account in REST in records' API form: one the asker may not see is { id: null, hidden: true }, never a
  # name or a login; one shown has its id and the fields asked for and, with records, records' mark (restricted,
  # hidden_from) when some other user may not see it. Records' GkRecords::Visibility.api_user decides when records is
  # there, otherwise core's rule (GkPeople::Accounts.visible_account?). No account (none, or removed) keeps the id
  # with empty fields.
  def api_account(id, user, fields)
    return { id: id }.merge(fields.index_with(nil)) if id.nil? || user.nil?

    vis = GkPeople::Accounts.records_visibility
    if vis.respond_to?(:api_user)
      a = vis.api_user(:user_id, id, user)
      return { id: nil, hidden: true } if a[:user_hidden]

      mark = a[:user_restricted] ? { restricted: true, hidden_from: a[:user_hidden_from] } : {}
    else
      return { id: nil, hidden: true } unless GkPeople::Accounts.visible_account?(user, User.current)

      mark = {}
    end
    { id: id }.merge(fields.index_with { |f| user.public_send(f) }).merge(mark)
  end

  # An account id in REST as records gives it: { key => id } for an account the asker may see, { key => nil, <key
  # without _id>_hidden: true } for one she may not, so the id never tells that the account is there. Records'
  # GkRecords::Visibility.api_user decides when records is there (and adds its mark for an account not everyone
  # may see), otherwise core's rule (GkPeople::Accounts.visible_account?, User.visible; an administrator sees
  # all). No account keeps the id.
  def api_account_id(key, id, user)
    vis = GkPeople::Accounts.records_visibility
    return vis.api_user(key, id, user, User.current) if vis.respond_to?(:api_user)
    return { key => id } if id.nil? || user.nil?
    return { key => id } if GkPeople::Accounts.visible_account?(user, User.current)

    { key => nil, key.to_s.sub(/_id\z/, '_hidden').to_sym => true }
  end

  def render_errors(record)
    respond_to do |format|
      format.html { render(record.persisted? ? :edit : :new, status: 422) }
      format.json { render json: { errors: record.errors.full_messages }, status: 422 }
    end
  end
end
