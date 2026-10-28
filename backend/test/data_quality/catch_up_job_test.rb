require "test_helper"

# The hourly catch-up (#188): a run cut off by a restart is marked failed,
# and today's daily crawl is queued again once, from the first source the
# daily job started but never finished.
class DataQuality::CatchUpJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  Job = DataQuality::CatchUpJob
  NOW = Time.find_zone("America/New_York").local(2026, 10, 12, 6, 30)
  AT_3AM = NOW.change(hour: 3, min: 1)

  setup { Job::CACHE.clear }

  def catch_up(at: NOW) = Job.new.perform(now: at)
  def started(kind) = Job.daily_started!(kind, now: AT_3AM)
  def finished(kind) = Job.daily_finished!(kind, now: AT_3AM)

  # Runs the daily job with Pipeline.run stubbed to raise `error` for `kind`.
  def daily(error_for = {})
    pipeline = DataQuality::Pipeline.singleton_class
    original = pipeline.instance_method(:run)
    pipeline.define_method(:run) { |kind, **| error_for[kind] ? raise(error_for[kind]) : [] }
    DataQuality::DailyCrawlJob.new.perform
  rescue StandardError
    nil # the job re-raises the first failure; the marks are what's checked
  ensure
    pipeline.define_method(:run, original)
  end

  test "a run cut off by a restart is failed, and the crawl is queued again from that source, once" do
    started("nrc_reactor_list")
    cut_off = CrawlRun.create!(source_kind: "nrc_reactor_list", stage: "extract", status: "running", started_at: AT_3AM)

    catch_up

    assert_equal DataQuality::Pipeline::ABANDONED, cut_off.reload.error
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news] ]

    clear_enqueued_jobs
    catch_up(at: NOW + 1.hour)
    # Once a day, so a source that keeps failing waits for a person.
    assert_no_enqueued_jobs only: DataQuality::DailyCrawlJob
  end

  test "the night of 12 Oct: NRC fetched, then failed on the key; EIA cut off. Only EIA is queued again" do
    started("nrc_reactor_list")
    finished("nrc_reactor_list") # failed on the key: an ordinary failure, it finished
    started("eia_generators")

    catch_up

    # NRC isn't fetched again today: it goes through data_quality:rerun, from its snapshot.
    assert_enqueued_jobs 1, only: DataQuality::DailyCrawlJob
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news] ]
  end

  test "a restart between stages, with no run left running, is caught up too" do
    finished("nrc_reactor_list")
    started("eia_generators") # its crawl succeeded, and extract never started
    CrawlRun.create!(source_kind: "eia_generators", stage: "crawl", status: "succeeded", started_at: AT_3AM)

    catch_up

    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news] ]
  end

  test "a run started by hand is never taken for a cut-off daily crawl" do
    finished("nrc_reactor_list")
    finished("eia_generators")
    finished("usaspending_doe_awards")
    finished("nrc_decommissioning")
    finished("doe_isotope_sites")
    finished("nrc_uranium_recovery")
    finished("company_newsrooms")
    finished("nrc_reactor_vendors")
    finished("nrc_fuel_cycle")
    finished("nrc_research_reactors")
    finished("doe_programs")
    finished("federal_register_nrc")
    finished("trade_press")
    finished("sec_form_d")
    finished("nasa_nuclear_news")
    finished("first_read_pages")
    finished("doe_nuclear_news")
    finished("arpa_e_projects")
    finished("doe_loans")
    finished("nrc_news")
    CrawlRun.create!(source_kind: "eia_generators", stage: "crawl", status: "succeeded", started_at: NOW - 1.hour)

    catch_up

    assert_no_enqueued_jobs only: DataQuality::DailyCrawlJob
  end

  test "the daily job marks each source started and finished, failures included" do
    travel_to(AT_3AM) { daily("nrc_reactor_list" => RuntimeError.new("OpenRouter rejected the API key")) }

    # Read at the same moment: the marks expire two days after they're written.
    travel_to(AT_3AM) do
      %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news].each do |kind|
        assert Job.marked?(:started, kind, AT_3AM.to_date), kind
        assert Job.marked?(:finished, kind, AT_3AM.to_date), "#{kind}: an ordinary failure counts as finished"
      end
    end
  end

  test "a source the daily job found busy isn't marked started, since it requeues itself" do
    travel_to(AT_3AM) { daily("nrc_reactor_list" => DataQuality::Pipeline::AlreadyRunning.new) }

    travel_to(AT_3AM) { assert_not Job.marked?(:started, "nrc_reactor_list", AT_3AM.to_date) }
  end

  test "waits while a daily source is really mid-run, so EIA never starts alongside NRC" do
    started("nrc_reactor_list")
    nrc = CrawlRun.create!(source_kind: "nrc_reactor_list", stage: "extract", status: "running", started_at: AT_3AM)
    config = ActiveRecord::Base.connection_db_config
    other = PG.connect(host: config.configuration_hash[:host], port: config.configuration_hash[:port],
      dbname: config.database, user: config.configuration_hash[:username], password: config.configuration_hash[:password])
    other.exec("SELECT pg_advisory_lock(#{Zlib.crc32('data_quality:nrc_reactor_list')})")

    catch_up

    assert nrc.reload.running?, "its lock is held, so it's working"
    assert_no_enqueued_jobs only: DataQuality::DailyCrawlJob
  ensure
    other&.exec("SELECT pg_advisory_unlock_all()")
    other&.close
  end

  test "if queueing fails, nothing is remembered, so the next hour tries again" do
    failing = DataQuality::DailyCrawlJob.singleton_class
    original = failing.instance_method(:perform_later)
    failing.define_method(:perform_later) { |*| raise ActiveJob::EnqueueError, "queue unavailable" }
    assert_raises(ActiveJob::EnqueueError) { catch_up }
    failing.define_method(:perform_later, original)

    catch_up(at: NOW + 1.hour)

    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news] ]
  ensure
    failing.define_method(:perform_later, original)
  end

  test "a daily crawl that never started is queued after 4am" do
    catch_up(at: NOW.change(hour: 3, min: 30))
    assert_no_enqueued_jobs only: DataQuality::DailyCrawlJob

    catch_up
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news] ]
  end

  test "yesterday's marks don't count for today" do
    Job.daily_finished!("nrc_reactor_list", now: AT_3AM - 1.day)
    Job.daily_finished!("eia_generators", now: AT_3AM - 1.day)

    catch_up

    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news] ]
  end

  test "runs hourly in production" do
    task = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "data_quality_catch_up")
    recurring = SolidQueue::RecurringTask.from_configuration("data_quality_catch_up", **task.symbolize_keys)

    assert recurring.valid?, recurring.errors.full_messages.to_sentence
    assert_equal "DataQuality::CatchUpJob", task["class"]
  end
end
