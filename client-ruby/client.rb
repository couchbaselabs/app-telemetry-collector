# frozen_string_literal: true

require "websocket-client-simple"

class Command
  GET_TELEMETRY = 0
end

class Status
  SUCCESS = 0
  UNKNOWN_COMMAND = 1
end

class TelemetryStore
  def initialize
    @agent = "ruby/1.2.3 (Ruby/#{RUBY_VERSION})"
    reset_metrics
  end

  def total(service, bucket, host)
    @counters[bucket][host]["sdk_#{service}_r_total"] += 1
  end

  def ambiguous_timeout(service, bucket, host)
    @counters[bucket][host]["sdk_#{service}_r_atimedout"] += 1
  end

  def unambiguous_timeout(service, bucket, host)
    @counters[bucket][host]["sdk_#{service}_r_utimedout"] += 1
  end

  def cancelled(service, bucket, host)
    @counters[bucket][host]["sdk_#{service}_r_canceled"] += 1
  end

  def record_latency(service, bucket, host, latency_sec)
    metric =
      if service == :kv
        "sdk_#{service}_#{[:retrieval, :mutation_durable, :mutation_nondurable].sample}_duration_seconds"
      else
        "sdk_#{service}_duration_seconds"
      end
    histogram = @histograms[bucket][host][metric]
    histogram.each_key do |upper_bound|
      histogram[upper_bound] += 1 if upper_bound.is_a?(Numeric) && latency_sec <= upper_bound
    end
    histogram["count"] += 1
    histogram["sum"] += latency_sec
  end

  def reset_metrics
    @counters = Hash.new do |level_1, bucket|
      level_1[bucket] = Hash.new do |level_2, host|
        level_2[host] = Hash.new(0)
      end
    end
    @histograms = Hash.new do |level_1, bucket|
      level_1[bucket] = Hash.new do |level_2, host|
        level_2[host] = {
          "sdk_kv_retrieval_duration_seconds" => {
            0.001 => 0,
            0.01 => 0,
            0.1 => 0,
            0.5 => 0,
            1 => 0,
            2.5 => 0,
            Float::INFINITY => 0,
            "sum" => 0,
            "count" => 0,
          },
          "sdk_kv_mutation_nondurable_duration_seconds" => {
            0.001 => 0,
            0.01 => 0,
            0.1 => 0,
            0.5 => 0,
            1 => 0,
            2.5 => 0,
            Float::INFINITY => 0,
            "sum" => 0,
            "count" => 0,
          },
          "sdk_kv_mutation_durable_duration_seconds" => {
            0.01 => 0,
            0.1 => 0,
            1 => 0,
            2 => 0,
            5 => 0,
            10 => 0,
            Float::INFINITY => 0,
            "sum" => 0,
            "count" => 0,
          },
          "sdk_query_duration_seconds" => {
            0.1 => 0,
            1 => 0,
            10 => 0,
            30 => 0,
            75 => 0,
            Float::INFINITY => 0,
            "sum" => 0,
            "count" => 0,
          },
          "sdk_search_duration_seconds" => {
            0.1 => 0,
            1 => 0,
            10 => 0,
            30 => 0,
            75 => 0,
            Float::INFINITY => 0,
            "sum" => 0,
            "count" => 0,
          },
          "sdk_analytics_duration_seconds" => {
            0.1 => 0,
            1 => 0,
            10 => 0,
            30 => 0,
            75 => 0,
            Float::INFINITY => 0,
            "sum" => 0,
            "count" => 0,
          },
        }
      end
    end
  end

  def histogram_label(upper_bound)
    return "+Inf" if upper_bound.infinite?

    format("%0.3g", upper_bound).sub(/0+$/, "")
  end

  def export
    # milliseconds from Epoch (1970-01-01 00:00:00 UTC)
    scrapping_timestamp = (Time.now.to_f * 1000).to_i
    counters = @counters
    histograms = @histograms
    reset_metrics
    report = []
    counters.each do |bucket, level_2|
      level_2.each do |host, level_3|
        level_3.each do |metric, value|
          report << "#{metric}{agent=#{@agent.inspect},bucket=#{bucket.inspect},node=#{host.inspect}} #{value.round} #{scrapping_timestamp}"
        end
      end
    end
    histograms.each do |bucket, level_2|
      level_2.each do |host, level_3|
        level_3.each do |metric, histogram|
          histogram.each do |label, value|
            report << if label.is_a?(Numeric)
                        "#{metric}_bucket{le=#{histogram_label(label).inspect},agent=#{@agent.inspect},bucket=#{bucket.inspect},node=#{host.inspect}} #{value.round} #{scrapping_timestamp}"
                      else
                        "#{metric}_#{label}{agent=#{@agent.inspect},bucket=#{bucket.inspect},node=#{host.inspect}} #{value.round}"
                      end
          end
        end
      end
    end
    report.join("\n")
  end
end

class Reporter
  attr_accessor :ws, :store

  def initialize(store, url: "ws://localhost:8091/app_telemetry")
    @ws = WebSocket::Client::Simple.connect(url)
    @store = store
  end

  def start
    reporter = self
    @ws.on(:message) do |msg|
      case msg.type
      when :close
        puts "Server closed connection"
      when :ping
        reporter.ws.send(nil, type: :pong)
      when :binary
        case msg.data[0].to_i
        when Command::GET_TELEMETRY
          report = reporter.store.export
          reporter.ws.send([Status::SUCCESS, report].pack("Ca*"), type: :binary)
        else
          reporter.ws.send([Status::UNKNOWN_COMMAND].pack("C"), type: :binary)
        end
      end
    end
  end
end

telemetry = TelemetryStore.new
reporter = Reporter.new(telemetry)
reporter.start

services = [:kv, :query, :search, :analytics]
buckets = %w[default foo bar travel-sample]
hosts = ["example.com", "example.org", "example.net"]
statuses = [:success, :error, :ambiguous_timeout, :unambiguous_timeout, :cancelled]

loop do
  service = services.sample
  bucket = buckets.sample
  host = hosts.sample
  status = statuses.sample

  telemetry.total(service, bucket, host)
  case status
  when :ambiguous_timeout
    telemetry.ambiguous_timeout(service, bucket, host)
  when :unambiguous_timeout
    telemetry.unambiguous_timeout(service, bucket, host)
  when :cancelled
    telemetry.cancelled(service, bucket, host)
  when :success
    telemetry.record_latency(service, bucket, host, rand(0.01..3.0))
  end
end
