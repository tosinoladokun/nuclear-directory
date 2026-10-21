namespace :preview do
  desc "Create or update the preview's admin login from PREVIEW_ADMIN_PASSWORD (preview only; run by bin/preview-start.sh)"
  task admin: :environment do
    puts PreviewAdmin.ensure!
  rescue PreviewAdmin::NotPreview, ActiveRecord::RecordInvalid => error
    abort "preview:admin: #{error.message}"
  end
end
