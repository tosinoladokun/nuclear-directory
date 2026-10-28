require "test_helper"
require "fugit"

# The daily crawl (#53): config/recurring.yml runs the whole pipeline once a
# day in production, NRC then EIA.
class DataQuality::DailyCrawlScheduleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def task = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").fetch("daily_crawl")

  # Runs the job with Pipeline.run stubbed: records each call, and raises
  # what `fail` gives for a source kind.
  def run_daily(*args, fail: {}, **options)
    ran = []
    pipeline = DataQuality::Pipeline.singleton_class
    original = pipeline.instance_method(:run)
    pipeline.define_method(:run) do |source_kind, only: nil, **|
      ran << [ source_kind, only ]
      raise fail[source_kind] if fail[source_kind]
      []
    end
    error = begin
      DataQuality::DailyCrawlJob.new.perform(*args, **options)
      nil
    rescue StandardError => raised
      raised
    end
    [ ran, error ]
  ensure
    pipeline.define_method(:run, original)
  end

  test "Solid Queue accepts the schedule, and every source it runs has a plug-in" do
    recurring = SolidQueue::RecurringTask.from_configuration("daily_crawl", **task.symbolize_keys)

    assert recurring.valid?, recurring.errors.full_messages.to_sentence
    assert_equal "DataQuality::DailyCrawlJob", task["class"]
    DataQuality::DailyCrawlJob::SOURCE_KINDS.each { |kind| assert DataQuality::Plugin.for(kind), "#{kind} has a plug-in" }
    assert_equal "nrc_news", DataQuality::DailyCrawlJob::SOURCE_KINDS.last, "the newest source runs daily, last"
  end

  test "it runs once a day at 3am Eastern, through the change back from daylight saving time" do
    schedule = Fugit.parse(task["schedule"])
    times = 5.times.each_with_object([ schedule.next_time(Time.utc(2026, 10, 30, 12)).to_t ]) do |_, list|
      list << schedule.next_time(list.last).to_t
    end
    local = times.map { |time| time.in_time_zone("America/New_York") }

    assert_equal (Date.new(2026, 10, 31)..Date.new(2026, 11, 5)).to_a, local.map(&:to_date)
    assert_equal [ 3 ] * 6, local.map(&:hour)
  end

  test "it runs the whole pipeline for NRC, then EIA, then DOE awards, NRC decommissioning, DOE isotope sites and NRC uranium recovery" do
    ran, error = run_daily

    assert_nil error
    assert_equal [ [ "nrc_reactor_list", nil ], [ "eia_generators", nil ], [ "usaspending_doe_awards", nil ], [ "nrc_decommissioning", nil ], [ "doe_isotope_sites", nil ], [ "nrc_uranium_recovery", nil ], [ "company_newsrooms", nil ], [ "nrc_reactor_vendors", nil ], [ "nrc_fuel_cycle", nil ], [ "nrc_research_reactors", nil ], [ "doe_programs", nil ], [ "federal_register_nrc", nil ], [ "trade_press", nil ], [ "sec_form_d", nil ], [ "nasa_nuclear_news", nil ], [ "first_read_pages", nil ], [ "doe_nuclear_news", nil ], [ "arpa_e_projects", nil ], [ "doe_loans", nil ], [ "nrc_news", nil ] ], ran
  end

  test "a failing source doesn't stop the next one, and the job still fails" do
    ran, error = run_daily(fail: { "nrc_reactor_list" => RuntimeError.new("NRC page changed") })

    assert_equal %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news], ran.map(&:first)
    assert_equal "NRC page changed", error.message
  end

  test "a source already being run is retried later on its own, without running NRC again" do
    busy = DataQuality::Pipeline::AlreadyRunning.new

    ran, error = run_daily(fail: { "eia_generators" => busy })

    assert_equal %w[nrc_reactor_list eia_generators], ran.map(&:first)
    assert_nil error
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news], { attempt: 2 } ]
  end

  test "a busy source doesn't run the ones after it alongside, and earlier failures still fail the job" do
    ran, error = run_daily(fail: { "nrc_reactor_list" => DataQuality::Pipeline::AlreadyRunning.new })
    assert_equal %w[nrc_reactor_list], ran.map(&:first), "EIA waits for NRC"
    assert_nil error
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news], { attempt: 2 } ]

    clear_enqueued_jobs
    _, error = run_daily(fail: { "nrc_reactor_list" => RuntimeError.new("NRC page changed"),
      "eia_generators" => DataQuality::Pipeline::AlreadyRunning.new })
    assert_equal "NRC page changed", error.message
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news], { attempt: 2 } ]
  end

  test "after the last attempt a busy source fails the job" do
    _, error = run_daily([ "eia_generators" ], attempt: DataQuality::DailyCrawlJob::ATTEMPTS,
      fail: { "eia_generators" => DataQuality::Pipeline::AlreadyRunning.new })

    assert_kind_of DataQuality::Pipeline::AlreadyRunning, error
    assert_no_enqueued_jobs only: DataQuality::DailyCrawlJob
  end

  test "each source gets its own attempts: EIA's count starts over after NRC waited" do
    ran, error = run_daily(attempt: DataQuality::DailyCrawlJob::ATTEMPTS - 1,
      fail: { "eia_generators" => DataQuality::Pipeline::AlreadyRunning.new })

    assert_equal %w[nrc_reactor_list eia_generators], ran.map(&:first)
    assert_nil error
    assert_enqueued_with job: DataQuality::DailyCrawlJob, args: [ %w[eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d nasa_nuclear_news first_read_pages doe_nuclear_news arpa_e_projects doe_loans nrc_news], { attempt: 2 } ]
  end
end
