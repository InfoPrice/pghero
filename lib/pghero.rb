require "pghero/version"
require "active_record"

# methods
require "pghero/methods/basic"
require "pghero/methods/connections"
require "pghero/methods/explain"
require "pghero/methods/indexes"
require "pghero/methods/kill"
require "pghero/methods/maintenance"
require "pghero/methods/queries"
require "pghero/methods/query_stats"
require "pghero/methods/replication"
require "pghero/methods/sequences"
require "pghero/methods/space"
require "pghero/methods/suggested_indexes"
require "pghero/methods/system"
require "pghero/methods/tables"
require "pghero/methods/users"

require "pghero/database"
require "pghero/engine" if defined?(Rails)

# models
require "pghero/connection"
require "pghero/query_stats"

module PgHero
  class MissingRequirement < StandardError; end

  # settings
  class << self
    attr_accessor :long_running_query_sec, :slow_query_ms, :slow_query_calls, :total_connections_threshold, :cache_hit_rate_threshold, :env, :show_migrations
  end
  self.long_running_query_sec = (ENV["PGHERO_LONG_RUNNING_QUERY_SEC"] || 60).to_i
  self.slow_query_ms = (ENV["PGHERO_SLOW_QUERY_MS"] || 20).to_i
  self.slow_query_calls = (ENV["PGHERO_SLOW_QUERY_CALLS"] || 100).to_i
  self.total_connections_threshold = (ENV["PGHERO_TOTAL_CONNECTIONS_THRESHOLD"] || 100).to_i
  self.cache_hit_rate_threshold = 99
  self.env = ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
  self.show_migrations = true

  class << self
    extend Forwardable
    def_delegators :primary_database, :access_key_id, :analyze, :analyze_tables, :autoindex, :autovacuum_danger,
      :best_index, :blocked_queries, :connection_sources, :connection_stats,
      :cpu_usage, :create_user, :database_size, :db_instance_identifier, :disable_query_stats, :drop_user,
      :duplicate_indexes, :enable_query_stats, :explain, :historical_query_stats_enabled?, :index_caching,
      :index_hit_rate, :index_usage, :indexes, :invalid_indexes, :kill, :kill_all, :kill_long_running_queries,
      :last_stats_reset_time, :long_running_queries, :maintenance_info, :missing_indexes, :query_stats,
      :query_stats_available?, :query_stats_enabled?, :query_stats_extension_enabled?, :query_stats_readable?,
      :rds_stats, :read_iops_stats, :region, :relation_sizes, :replica?, :replication_lag, :replication_lag_stats,
      :reset_query_stats, :reset_stats, :running_queries, :secret_access_key, :sequence_danger, :sequences, :settings,
      :slow_queries, :space_growth, :ssl_used?, :stats_connection, :suggested_indexes, :suggested_indexes_by_query,
      :suggested_indexes_enabled?, :system_stats_enabled?, :table_caching, :table_hit_rate, :table_stats,
      :total_connections, :transaction_id_danger, :unused_indexes, :unused_tables, :write_iops_stats

    def time_zone=(time_zone)
      @time_zone = time_zone.is_a?(ActiveSupport::TimeZone) ? time_zone : ActiveSupport::TimeZone[time_zone.to_s]
    end

    def time_zone
      @time_zone || Time.zone
    end

    def config
      @config ||= begin
        path = "config/pghero.yml"

        config_file_exists = File.exist?(path)

        config = YAML.load(ERB.new(File.read(path)).result) if config_file_exists
        config ||= {}

        if config[env]
          config[env]
        elsif config["databases"] # preferred format
          config
        elsif config_file_exists
          raise "Invalid config file"
        else
          {
            "databases" => {
              "primary" => {
                "url" => ENV["PGHERO_DATABASE_URL"] || ActiveRecord::Base.connection_config,
                "db_instance_identifier" => ENV["PGHERO_DB_INSTANCE_IDENTIFIER"]
              }
            }
          }
        end
      end
    end

    def databases
      @databases ||= begin
        Hash[
          config["databases"].map do |id, c|
            [id.to_sym, PgHero::Database.new(id, c)]
          end
        ]
      end
    end

    def primary_database
      databases.values.first
    end

    def capture_query_stats
      databases.each do |_, database|
        database.capture_query_stats
      end
      true
    end

    def capture_space_stats
      databases.each do |_, database|
        database.capture_space_stats
      end
      true
    end

    def analyze_all(**options)
      databases.reject { |_, d| d.replica? }.each do |_, database|
        database.analyze_tables(**options)
      end
      true
    end

    def autoindex_all(create: false)
      databases.each do |_, database|
        puts "Autoindexing #{database}..."
        database.autoindex(create: create)
      end
      true
    end

    def pretty_size(value)
      ActiveSupport::NumberHelper.number_to_human_size(value, precision: 3)
    end
  end
end
