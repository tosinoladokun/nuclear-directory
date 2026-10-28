Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The directory and search results: one page for browsing and searching (#40).
  get "companies" => "directory#index", as: :companies
  get "companies/:slug" => "companies#show", as: :company
  get "plants/:slug" => "plants#show", as: :plant
  get "corrections/new" => "corrections#new", as: :new_correction
  post "corrections" => "corrections#create", as: :corrections
  get "corrections/sent" => "corrections#sent", as: :correction_sent

  # Link-preview images (#245), one per page, addressed by what they show.
  get "cards/:kind/:digest.png" => "link_cards#show", as: :link_card_default, format: false, constraints: { kind: "default" }
  get "cards/:kind/:key/:digest.png" => "link_cards#show", as: :link_card, format: false,
    constraints: { kind: /plants|companies|categories/ }

  get "about" => "pages#about", as: :about
  get "privacy" => "pages#privacy", as: :privacy
  get "disclaimer" => "pages#disclaimer", as: :disclaimer
  get "bot" => "pages#bot", as: :bot
  get "sitemap.xml" => "sitemaps#show", as: :sitemap, format: false, defaults: { format: :xml }
  get "robots.txt" => "sitemaps#robots", as: :robots, format: false
  get "llms.txt" => "sitemaps#llms", as: :llms, format: false
  # A public JSON summary for other sites (#193). GET only.
  get "api/snapshot.json" => "api/snapshots#show", as: :api_snapshot, format: false, defaults: { format: :json }
  # Data Quality's matching actions (#548): token only, 404 without one configured.
  scope "api/dq", module: "api/dq", defaults: { format: :json } do
    get "matching" => "matching#index", as: :api_dq_matching
    post "matching" => "matching#create"
    post "matching/undo" => "matching#undo", as: :api_dq_matching_undo
  end
  # The browser's PostHog traffic, through our site with the visitor's country (#205).
  match "relay/*path" => "relay#forward", via: %i[get post], format: false

  # The home page and its instant search (#41). /search returns a Turbo Frame
  # of grouped results for the home and header search fields.
  root "home#show"
  get "search" => "search#index", as: :search

  # The admin (#86): one account, signed in at /admin/session/sign-in. Every
  # decision goes through DataQuality::Review.
  resource :session, only: %i[new create destroy], path: "admin/session", path_names: { new: "sign-in" }
  namespace :admin do
    # Admin v2 (#201): Overview, Sources, Checks (where claims and pending
    # facts are approved) and Correction requests. The actions underneath
    # are today's: candidates, pending facts, corrections, facts.
    root "overview#show"
    get "sources" => "sources#index", as: :sources
    get "sources/search" => "sources#search", as: :sources_search
    get "sources/:key" => "sources#show", as: :source, constraints: { key: /[a-z0-9_-]+/ }
    get "status", to: redirect("/admin")
    # Today (#373): the day's review in four steps. Checks stays as step 3's list.
    # Tosin's inbox (#548): what he decides.
    get "inbox" => "inbox#show", as: :inbox
    post "inbox/yes_all" => "inbox#yes_all", as: :inbox_yes_all
    post "inbox/undo" => "inbox#undo", as: :inbox_undo
    post "inbox/:candidate_id/:decision" => "inbox#decide", as: :inbox_decide, constraints: { decision: /yes|no/ }
    get "today" => "today#show", as: :today
    post "today/list" => "today#list", as: :today_list
    # Step 3 (#373 part C): each fact with Joy's and Aminah's verdicts, decided here.
    get "today/review" => "today#review", as: :today_review
    post "today/review/agreed" => "today#agreed", as: :today_review_agreed
    post "today/review/undo" => "today#undo_decision", as: :today_review_undo
    post "today/review/:candidate_id/:decision" => "today#decide", as: :today_review_decide,
      constraints: { candidate_id: /\d+/, decision: /accept|reject|close/ }
    post "today/steps/:step" => "today#done", as: :today_step, constraints: { step: /crawl|list/ }
    delete "today/steps/:step" => "today#undo", constraints: { step: /crawl|list/ }
    get "checks" => "checks#show", as: :checks
    # Where it appears (#166): what the public sees of the directory, and where.
    get "where-it-appears" => "outputs#show", as: :outputs
    # Removed (#166): everything off the site now, with the decision that took it off.
    get "removed" => "removed#show", as: :removed
    # Data Quality's recommendations (#306): paste its list, see exactly
    # what Accept will do, then accept them as one decision.
    scope "checks/recommendations", as: :recommendations do
      get "/" => "recommendations#show"
      post "/" => "recommendations#create"
      post "accept" => "recommendations#accept", as: :accept
    end
    # Live (#201 part 2): every record with Data Quality's tag filters, and
    # a company's or plant's Record page.
    get "live" => "live#show", as: :live
    # Add a record by hand (#202): previewed with a GET, created with a POST.
    get "records/new" => "new_records#new", as: :new_record
    post "records" => "new_records#create", as: :new_records
    scope "records/:type/:id", as: :record, constraints: { type: /Organization|Facility/, id: /\d+/ } do
      get "/" => "records#show"
      get "edit" => "records#edit", as: :edit
      patch "/" => "records#update"
      # Merge into… (#142): pick the record it's the same as, see what moves, confirm.
      get "merge" => "records#merge", as: :merge
      post "merge" => "records#perform_merge"
      # Add a fact by hand (#202): previewed with a GET, added with a POST.
      get "facts/new" => "record_facts#new", as: :new_fact
      post "facts" => "record_facts#create", as: :facts
      # Publish a record not yet public (#202): previewed, then confirmed.
      get "publish" => "record_publish#show", as: :publish
      post "publish" => "record_publish#create"
      # Enrich (#479): read a company's own pages against the field list, and decide what they found here.
      get "enrich" => "record_enrich#show", as: :enrich
      post "enrich" => "record_enrich#create"
      post "enrich/agreed" => "record_enrich#agreed", as: :enrich_agreed
      post "enrich/:candidate_id/:decision" => "record_enrich#decide", as: :enrich_decide,
        constraints: { candidate_id: /\d+/, decision: /approve|reject/ }
    end
    # Change status on a plant or a unit (#316): the form previews with a GET.
    scope "facilities/:id/status", as: :facility_status, constraints: { id: /\d+/ } do
      get "/" => "status_changes#edit"
      patch "/" => "status_changes#update"
    end
    # "Same as…" (#391): settle a claim's company that's still a question.
    get "candidates/:id/settle" => "candidate_settles#show", as: :candidate_settle, constraints: { id: /\d+/ }
    post "candidates/:id/settle" => "candidate_settles#create", constraints: { id: /\d+/ }
    resources :candidates, only: %i[index edit update] do
      collection do
        post :approve
        post :approve_all, path: "approve-all"
        post :reject
        post :close
      end
    end
    resources :pending_facts, only: :index, path: "pending" do
      collection do
        post :approve
        post :reject
      end
    end
    resources :leads, only: %i[index create] do
      collection { post :refresh }
      member do
        post :research
        post :covered
        post :ignore
        post :reopen
      end
    end
    resources :corrections, only: :index do
      member do
        post :start
        post :fix
        post :dismiss
        post :reopen
      end
    end
    scope "facts/:type/:id", as: :fact, constraints: { type: /[A-Z][A-Za-z]+/, id: /\d+/ } do
      get "/" => "facts#show"
      post "unpublish" => "facts#unpublish", as: :unpublish
      post "republish" => "facts#republish", as: :republish
      # Edit a unit or a link (#201, related items on a Record): the Record's edit flow.
      get "edit" => "records#edit", as: :edit, defaults: { page: "fact" }
      patch "/" => "records#update", defaults: { page: "fact" }
    end
  end

  # Living reference for the design system (see DESIGN.md). Not public.
  get "design" => "design_system#show", as: :design_system if Rails.env.local?
  # Development shows Rails' debug page for a 404; this previews the real one.
  get "design/not-found/*path" => "errors#not_found", format: false if Rails.env.local?

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
