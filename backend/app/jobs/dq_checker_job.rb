# The nightly checker (#776), in shadow: verdicts go to checker_verdicts only. Never in a web request.
class DqCheckerJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dq_checker", duration: 1.hour if respond_to?(:limits_concurrency)

  def perform = DqChecker.new.run
end
