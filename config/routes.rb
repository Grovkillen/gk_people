# frozen_string_literal: true

# Personer and Organisationer (top menu), the schemes and Personuppgifter (Administration), the extract and the REST
# under /gk_people
scope 'gk_people' do
  get 'name_links', to: 'gk_people_name_links#index', as: 'gk_people_name_links'
  # An account's own picture, one size, and the picture from its organization's folder
  get 'avatars/:user_id/folder/:size', to: 'gk_people_avatars#folder', as: 'gk_people_avatar_folder', constraints: { user_id: /\d+/, size: /\d+/ }
  # Changing it (step 4): the page, a new picture, removing it, the part of the folder's picture, and that file as it is
  get 'avatars/:user_id/edit', to: 'gk_people_avatars#edit', as: 'gk_people_avatar_edit', constraints: { user_id: /\d+/ }
  post 'avatars/:user_id', to: 'gk_people_avatars#update', as: 'gk_people_avatar_update', constraints: { user_id: /\d+/ }
  post 'avatars/:user_id/remove', to: 'gk_people_avatars#remove', as: 'gk_people_avatar_remove', constraints: { user_id: /\d+/ }
  get 'avatars/:user_id/original', to: 'gk_people_avatars#original', as: 'gk_people_avatar_original', constraints: { user_id: /\d+/ }
  get 'avatars/:user_id/:size', to: 'gk_people_avatars#show', as: 'gk_people_avatar', constraints: { user_id: /\d+/, size: /\d+/ }
  resources :gk_people_persons, path: 'persons', except: %i[destroy] do
    member do
      post :link
      post :unlink
    end
    collection do
      post :fill_accounts
      get :autocomplete
    end
    resources :gk_people_identifiers, path: 'identifiers', as: 'identifiers', only: %i[index create] do
      member { post 'end', action: :end_identifier, as: 'end' }
    end
  end
  resources :gk_people_organizations, path: 'organizations', except: %i[destroy]
  # An organization's relations and a person's consents; ended and revoked, never deleted
  post 'organizations/:id/relations', to: 'gk_people_relations#create', as: 'gk_people_relations'
  patch 'organizations/:id/relations/:relation_id/end', to: 'gk_people_relations#end_relation', as: 'gk_people_relation_end'
  post 'persons/:id/consents', to: 'gk_people_consents#create', as: 'gk_people_consents'
  patch 'persons/:id/consents/:consent_id/revoke', to: 'gk_people_consents#revoke', as: 'gk_people_consent_revoke'
  # The kinds of organization (Administration > Organisationstyper) and the import of organizations and persons
  # from CSV, in two steps
  resources :gk_people_org_kinds, path: 'org_kinds', except: %i[show destroy]
  get 'imports/template/:resource', to: 'gk_people_imports#template', as: 'gk_people_import_template', constraints: { resource: /organizations|persons/ }
  resources :gk_people_imports, path: 'imports', only: %i[index new create show update] do
    member do
      post :run
      post :discard
    end
  end
  resources :gk_people_groups, path: 'groups', except: %i[destroy] do
    member do
      get :members
      post :add_member, path: 'members'
      post :remove_member, path: 'members/remove'
      delete 'members/:person_id', action: :remove_member, as: 'member'
    end
  end
  resources :gk_people_schemes, path: 'schemes', except: %i[show destroy]
  # Organisation: responsibilities, holders and deputies (step 6), and who acts now
  resources :gk_people_responsibilities, path: 'responsibilities', except: %i[destroy] do
    member do
      get :holder
      post :assign
      post 'assignments/:assignment_id/end', action: :end_assignment, as: 'end'
      post 'assignments/:assignment_id/deputy', action: :deputy, as: 'deputy'
      post :add_rule, path: 'rules'
      post 'rules/:rule_id/remove', action: :remove_rule, as: 'remove_rule'
    end
  end
  # Intyg: credentials of persons and organizations (step 6, second part), revoked and never removed; their kinds
  # under Administration > Intygstyper
  resources :gk_people_credentials, path: 'credentials', only: %i[index new create edit update] do
    member { post :revoke }
  end
  resources :gk_people_credential_kinds, path: 'credential_kinds', except: %i[show destroy]
  # Roller från ansvar (role_sync, step 7): the page and Synka nu
  get 'role_sync', to: 'gk_people_role_sync#index', as: 'gk_people_role_sync'
  post 'role_sync', to: 'gk_people_role_sync#run', as: 'gk_people_role_sync_run'
  post 'identify', to: 'gk_people_persons#identify', as: 'gk_people_identify'
  resources :gk_people_processing, path: 'processing', only: %i[index edit update], constraints: { id: /[a-z0-9_]+/ }
  get 'persons/:id/subject_access', to: 'gk_people_subject_access#show', as: 'gk_people_subject_access'
  get 'my_data', to: 'gk_people_subject_access#mine', as: 'gk_people_my_data'
  # elevation: step up (the password again) and down, and the trace under Administration > Upphöjningar
  get 'elevate', to: 'gk_people_elevations#new', as: 'gk_people_elevate'
  post 'elevate', to: 'gk_people_elevations#create'
  post 'step_down', to: 'gk_people_elevations#step_down', as: 'gk_people_step_down'
  resources :gk_people_elevations, path: 'elevations', only: %i[index show]
  # sync: the upsert endpoints for the integration account, and their log
  post 'sync/:resource', to: 'gk_people_sync#create', as: 'gk_people_sync', constraints: { resource: /organizations|persons|groups/ }
  get 'sync_log', to: 'gk_people_sync#index', as: 'gk_people_sync_log'
  get 'sync_log/:id', to: 'gk_people_sync#show', as: 'gk_people_sync_log_entry', constraints: { id: /\d+/ }
  # actor_records: the search in the issue form on a shared account, and the records (REST and a page)
  get 'actor/search', to: 'gk_people_actor#search', as: 'gk_people_actor_search'
  get 'actor_records', to: 'gk_people_actor#index', as: 'gk_people_actor_records'
  # Vem är du? at a shared computer, choosing oneself and Klar
  get 'actor/who', to: 'gk_people_actor#who', as: 'gk_people_actor_who'
  post 'actor/who', to: 'gk_people_actor#choose'
  post 'actor/done', to: 'gk_people_actor#done', as: 'gk_people_actor_done'
  # Förläng: the choice held a while longer from the warning a minute before it runs out (no PIN again)
  post 'actor/prolong', to: 'gk_people_actor#prolong', as: 'gk_people_actor_prolong'
  get 'actor/pin', to: 'gk_people_actor#pin_form', as: 'gk_people_actor_pin'
  post 'actor/pin', to: 'gk_people_actor#pin'
  # a PIN: one's own (Mitt konto), or a start code set by an administrator on the person's page
  get 'my_pin', to: 'gk_people_pin#mine', as: 'gk_people_my_pin'
  post 'my_pin', to: 'gk_people_pin#update_mine'
  post 'persons/:id/pin', to: 'gk_people_pin#set_for_person', as: 'gk_people_person_pin', constraints: { id: /\d+/ }
  # the matrix of a shared account (an administrator, on the account)
  get 'shared_accounts/:user_id', to: 'gk_people_actor#matrix', as: 'gk_people_shared_account', constraints: { user_id: /\d+/ }
  post 'shared_accounts/:user_id', to: 'gk_people_actor#update_matrix', constraints: { user_id: /\d+/ }
  # Se som (see_as): the choice, starting and stopping, search among all and the mail preview; always as oneself
  get 'see_as', to: 'gk_people_see_as#new', as: 'gk_people_see_as_new'
  post 'see_as', to: 'gk_people_see_as#create', as: 'gk_people_see_as'
  get 'see_as/search', to: 'gk_people_see_as#search', as: 'gk_people_see_as_search'
  post 'see_as/stop', to: 'gk_people_see_as#stop', as: 'gk_people_see_as_stop'
  get 'see_as/mail', to: 'gk_people_see_as#mail', as: 'gk_people_see_as_mail'
  # Snabbkontakter: the line saved (one or several), the preview while typing, a part moved, Att komplettera with
  # Klar, Slå ihop and Det är olika, and Administration > Roller och avdelningar
  post 'quick', to: 'gk_people_quick#create', as: 'gk_people_quick'
  get 'quick/preview', to: 'gk_people_quick#preview', as: 'gk_people_quick_preview'
  get 'to_complete', to: 'gk_people_quick#index', as: 'gk_people_to_complete'
  post 'quick/:type/:id/move', to: 'gk_people_quick#move', as: 'gk_people_quick_move', constraints: { type: /person|organization/, id: /\d+/ }
  post 'quick/:type/:id/done', to: 'gk_people_quick#done', as: 'gk_people_quick_done', constraints: { type: /person|organization/, id: /\d+/ }
  get 'quick/:type/:id/merge', to: 'gk_people_quick#merge_page', as: 'gk_people_quick_merge', constraints: { type: /person|organization/, id: /\d+/ }
  post 'quick/:type/:id/merge', to: 'gk_people_quick#merge', constraints: { type: /person|organization/, id: /\d+/ }
  post 'quick/:type/:id/different', to: 'gk_people_quick#different', as: 'gk_people_quick_different', constraints: { type: /person|organization/, id: /\d+/ }
  get 'quick_words', to: 'gk_people_quick#words', as: 'gk_people_quick_words'
  post 'quick_words', to: 'gk_people_quick#update_words'
end
