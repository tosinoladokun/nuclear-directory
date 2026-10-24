# Decides which CI work a pull request needs, from the files it changes.
# lint and blueprint always run; this decides three things:
#
#   test       the unit tests (bin/rails test)
#   system     the browser tests (test/system)
#   lighthouse the mobile Lighthouse audit
#
# The jobs named test and lighthouse are required checks, so they always run
# and report; when this says false they say "skipped: ..." and pass.
#
#   docs only (Markdown, planning/)                      -> nothing
#   render.yaml, .github/ (except ci.yml), backup/ ...    -> unit tests
#   data (db/seeds, db/data, data_quality code and tests) -> unit tests
#   test files outside test/system                        -> unit tests
#   page code (views, assets, JavaScript, helpers,
#     controllers, routes, test/system)                   -> unit + system tests;
#                                                          Lighthouse only for the
#                                                          public pages' code
#   anything else, or nothing listed                     -> all three
#
# Run by CI (scope job) from the PR's base commit, so a PR can't edit its way
# out of tests: changed paths on stdin, one per line. Writes
# test=, system= and lighthouse= (true|false) to $GITHUB_OUTPUT (or stdout).
# Pushes to main never go through here: they run everything.
module CiScope
  DOCS = [
    /\.md\z/i,
    %r{\Aplanning/}
  ].freeze

  # Can't change the app or its pages, but tests still cover the scripts
  # and config around it. ci.yml and this classifier aren't here: a change
  # to how CI decides runs everything.
  INFRA = [
    %r{\Arender\.yaml\z},
    %r{\A\.github/(?!workflows/ci\.yml\z|scripts/ci_scope)},
    %r{\Abackup/},
    %r{\Adocker-compose[^/]*\.ya?ml\z},
    %r{\A\.env\.example\z},
    %r{\A\.gitignore\z}
  ].freeze

  # Records and the pipeline that finds them, with their unit tests. Nothing
  # here renders a page: the seeds and data steps load rows, and the crawler
  # plug-ins fetch and extract.
  DATA = [
    %r{\Abackend/db/seeds/},
    %r{\Abackend/db/data/},
    %r{\Abackend/app/data_quality/},
    %r{\Abackend/test/data_quality/},
    %r{\Abackend/test/seeds_test\.rb\z},
    %r{\Abackend/test/fixtures/files/}
  ].freeze

  # Tests that can't change what the browser sees.
  UNIT_TESTS = [
    %r{\Abackend/test/(?!system/|application_system_test_case\.rb\z)}
  ].freeze

  # Code the public pages are built from: what Lighthouse audits (the home,
  # directory and profile pages) and what the browser tests drive. The admin's
  # own views and controllers aren't audited, but the shared layout and
  # helpers are, so those count.
  PUBLIC_PAGES = [
    %r{\Abackend/app/views/(?!admin/)},
    %r{\Abackend/app/assets/},
    %r{\Abackend/app/javascript/},
    %r{\Abackend/app/helpers/},
    %r{\Abackend/config/routes\.rb\z},
    %r{\Abackend/app/controllers/(?!admin/|api/)}
  ].freeze

  # The browser tests also run for the admin's views, its controllers and the
  # tests themselves.
  BROWSER = [
    %r{\Abackend/app/views/admin/},
    %r{\Abackend/app/controllers/(admin|api)/},
    %r{\Abackend/test/system/},
    %r{\Abackend/test/application_system_test_case\.rb\z}
  ].freeze

  module_function

  def kind(path)
    return :docs if DOCS.any? { |pattern| path.match?(pattern) }
    return :infra if INFRA.any? { |pattern| path.match?(pattern) }
    return :data if DATA.any? { |pattern| path.match?(pattern) }
    return :page if PUBLIC_PAGES.any? { |pattern| path.match?(pattern) }
    return :browser if BROWSER.any? { |pattern| path.match?(pattern) }
    return :unit_test if UNIT_TESTS.any? { |pattern| path.match?(pattern) }

    :app
  end

  def scope(paths)
    kinds = paths.map(&:strip).reject(&:empty?).map { |path| kind(path) }
    # Nothing to go on: run everything.
    return { test: true, system: true, lighthouse: true } if kinds.empty?

    everything = kinds.include?(:app)
    page = kinds.include?(:page)
    {
      test: everything || (kinds - [ :docs ]).any?,
      system: everything || page || kinds.include?(:browser),
      lighthouse: everything || page
    }
  end
end

if $PROGRAM_NAME == __FILE__
  result = CiScope.scope($stdin.each_line.to_a)
  lines = result.map { |job, needed| "#{job}=#{needed}" }
  output = ENV["GITHUB_OUTPUT"]
  output ? File.open(output, "a") { |file| file.puts(lines) } : puts(lines)
  warn "CI scope: #{lines.join(', ')}"
end
