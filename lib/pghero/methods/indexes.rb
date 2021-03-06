module PgHero
  module Methods
    module Indexes
      def index_hit_rate
        select_one <<-SQL
          SELECT
            (sum(idx_blks_hit)) / nullif(sum(idx_blks_hit + idx_blks_read), 0) AS rate
          FROM
            pg_statio_user_indexes
        SQL
      end

      def index_caching
        select_all <<-SQL
          SELECT
            schemaname AS schema,
            relname AS table,
            indexrelname AS index,
            CASE WHEN idx_blks_hit + idx_blks_read = 0 THEN
              0
            ELSE
              ROUND(1.0 * idx_blks_hit / (idx_blks_hit + idx_blks_read), 2)
            END AS hit_rate
          FROM
            pg_statio_user_indexes
          ORDER BY
            3 DESC, 1
        SQL
      end

      def index_usage
        select_all <<-SQL
          SELECT
            schemaname AS schema,
            relname AS table,
            CASE idx_scan
              WHEN 0 THEN 'Insufficient data'
              ELSE (100 * idx_scan / (seq_scan + idx_scan))::text
            END percent_of_times_index_used,
            n_live_tup AS estimated_rows
          FROM
            pg_stat_user_tables
          ORDER BY
            n_live_tup DESC,
            relname ASC
         SQL
      end

      def missing_indexes
        select_all <<-SQL
          SELECT
            schemaname AS schema,
            relname AS table,
            CASE idx_scan
              WHEN 0 THEN 'Insufficient data'
              ELSE (100 * idx_scan / (seq_scan + idx_scan))::text
            END percent_of_times_index_used,
            n_live_tup AS estimated_rows
          FROM
            pg_stat_user_tables
          WHERE
            idx_scan > 0
            AND (100 * idx_scan / (seq_scan + idx_scan)) < 95
            AND n_live_tup >= 10000
          ORDER BY
            n_live_tup DESC,
            relname ASC
         SQL
      end

      def unused_indexes(max_scans: 50)
        select_all_size <<-SQL
          SELECT
            schemaname AS schema,
            relname AS table,
            indexrelname AS index,
            pg_relation_size(i.indexrelid) AS size_bytes,
            idx_scan as index_scans
          FROM
            pg_stat_user_indexes ui
          INNER JOIN
            pg_index i ON ui.indexrelid = i.indexrelid
          WHERE
            NOT indisunique
            AND idx_scan <= #{max_scans.to_i}
          ORDER BY
            pg_relation_size(i.indexrelid) DESC,
            relname ASC
        SQL
      end

      def reset_stats
        execute("SELECT pg_stat_reset()")
        true
      end

      def last_stats_reset_time
        select_one <<-SQL
          SELECT
            pg_stat_get_db_stat_reset_time(oid) AS reset_time
          FROM
            pg_database
          WHERE
            datname = current_database()
        SQL
      end

      def invalid_indexes
        select_all <<-SQL
          SELECT
            c.relname AS index
          FROM
            pg_catalog.pg_class c,
            pg_catalog.pg_namespace n,
            pg_catalog.pg_index i
          WHERE
            i.indisvalid = false
            AND i.indexrelid = c.oid
            AND c.relnamespace = n.oid
            AND n.nspname != 'pg_catalog'
            AND n.nspname != 'information_schema'
            AND n.nspname != 'pg_toast'
          ORDER BY
            c.relname
        SQL
      end

      # TODO parse array properly
      # http://stackoverflow.com/questions/2204058/list-columns-with-indexes-in-postgresql
      def indexes
        select_all(<<-SQL
          SELECT
            schemaname AS schema,
            t.relname AS table,
            ix.relname AS name,
            regexp_replace(pg_get_indexdef(i.indexrelid), '^[^\\(]*\\((.*)\\)$', '\\1') AS columns,
            regexp_replace(pg_get_indexdef(i.indexrelid), '.* USING ([^ ]*) \\(.*', '\\1') AS using,
            indisunique AS unique,
            indisprimary AS primary,
            indisvalid AS valid,
            indexprs::text,
            indpred::text,
            pg_get_indexdef(i.indexrelid) AS definition
          FROM
            pg_index i
          INNER JOIN
            pg_class t ON t.oid = i.indrelid
          INNER JOIN
            pg_class ix ON ix.oid = i.indexrelid
          LEFT JOIN
            pg_stat_user_indexes ui ON ui.indexrelid = i.indexrelid
          WHERE
            schemaname IS NOT NULL
          ORDER BY
            1, 2
        SQL
        ).map { |v| v[:columns] = v[:columns].sub(") WHERE (", " WHERE ").split(", ").map { |c| unquote(c) }; v }
      end

      def duplicate_indexes(indexes: nil)
        dup_indexes = []

        indexes_by_table = (indexes || self.indexes).group_by { |i| i[:table] }
        indexes_by_table.values.flatten.select { |i| !i[:primary] && !i[:unique] && !i[:indexprs] && !i[:indpred] && i[:valid] }.each do |index|
          covering_index = indexes_by_table[index[:table]].find { |i| index_covers?(i[:columns], index[:columns]) && i[:using] == index[:using] && i[:name] != index[:name] && i[:schema] == index[:schema] && !i[:indexprs] && !i[:indpred] && i[:valid] }
          if covering_index && (covering_index[:columns] != index[:columns] || index[:name] > covering_index[:name])
            dup_indexes << {unneeded_index: index, covering_index: covering_index}
          end
        end

        dup_indexes.sort_by { |i| ui = i[:unneeded_index]; [ui[:table], ui[:columns]] }
      end
    end
  end
end
