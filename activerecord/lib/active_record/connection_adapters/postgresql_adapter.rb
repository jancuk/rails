# Author: Luke Holden <lholden@cablelan.net>

require 'active_record/connection_adapters/abstract_adapter'
require 'parsedate'

module ActiveRecord
  class Base
    # Establishes a connection to the database that's used by all Active Record objects
    def self.postgresql_connection(config) # :nodoc:
      require_library_or_gem 'postgres' unless self.class.const_defined?(:PGconn)
      symbolize_strings_in_hash(config)
      host     = config[:host]
      port     = config[:port]     || 5432 unless host.nil?
      username = config[:username].to_s
      password = config[:password].to_s

      encoding = config[:encoding]
      min_messages = config[:min_messages]

      if config.has_key?(:database)
        database = config[:database]
      else
        raise ArgumentError, "No database specified. Missing argument: database."
      end

      pga = ConnectionAdapters::PostgreSQLAdapter.new(
        PGconn.connect(host, port, "", "", database, username, password), logger
      )

      pga.schema_search_path = config[:schema_search_path] || config[:schema_order]
      pga.execute("SET client_encoding TO '#{encoding}'") if encoding
      pga.execute("SET client_min_messages TO '#{min_messages}'") if min_messages

      pga
    end
  end

  module ConnectionAdapters
    # The PostgreSQL adapter works both with the C-based (http://www.postgresql.jp/interfaces/ruby/) and the Ruby-base
    # (available both as gem and from http://rubyforge.org/frs/?group_id=234&release_id=1145) drivers.
    #
    # Options:
    #
    # * <tt>:host</tt> -- Defaults to localhost
    # * <tt>:port</tt> -- Defaults to 5432
    # * <tt>:username</tt> -- Defaults to nothing
    # * <tt>:password</tt> -- Defaults to nothing
    # * <tt>:database</tt> -- The name of the database. No default, must be provided.
    # * <tt>:schema_search_path</tt> -- An optional schema search path for the connection given as a string of comma-separated schema names.  This is backward-compatible with the :schema_order option.
    # * <tt>:encoding</tt> -- An optional client encoding that is using in a SET client_encoding TO <encoding> call on connection.
    # * <tt>:min_messages</tt> -- An optional client min messages that is using in a SET client_min_messages TO <min_messages> call on connection.
    class PostgreSQLAdapter < AbstractAdapter
      def adapter_name
        'PostgreSQL'
      end

      def native_database_types
        {
          :primary_key => "serial primary key",
          :string      => { :name => "character varying", :limit => 255 },
          :text        => { :name => "text" },
          :integer     => { :name => "integer" },
          :float       => { :name => "float" },
          :datetime    => { :name => "timestamp" },
          :timestamp   => { :name => "timestamp" },
          :time        => { :name => "timestamp" },
          :date        => { :name => "date" },
          :binary      => { :name => "bytea" },
          :boolean     => { :name => "boolean"}
        }
      end
      
      def supports_migrations?
        true
      end      
      

      # QUOTING ==================================================

      def quote(value, column = nil)
        if value.class == String && column && column.type == :binary
          "'#{escape_bytea(value)}'"
        else
          super
        end
      end

      def quote_column_name(name)
        %("#{name}")
      end


      # DATABASE STATEMENTS ======================================

      def select_all(sql, name = nil) #:nodoc:
        select(sql, name)
      end

      def select_one(sql, name = nil) #:nodoc:
        result = select(sql, name)
        result.nil? ? nil : result.first
      end

      def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil) #:nodoc:
        execute(sql, name)
        table = sql.split(" ", 4)[2]
        return id_value || last_insert_id(table, pk)
      end

      def query(sql, name = nil) #:nodoc:
        log(sql, name) { @connection.query(sql) }
      end

      def execute(sql, name = nil) #:nodoc:
        log(sql, name) { @connection.exec(sql) }
      end

      def update(sql, name = nil) #:nodoc:
        execute(sql, name).cmdtuples
      end

      alias_method :delete, :update #:nodoc:


      def begin_db_transaction #:nodoc:
        execute "BEGIN"
      end

      def commit_db_transaction #:nodoc:
        execute "COMMIT"
      end
      
      def rollback_db_transaction #:nodoc:
        execute "ROLLBACK"
      end


      # SCHEMA STATEMENTS ========================================

      # Return the list of all tables in the schema search path.
      def tables(name = nil) #:nodoc:
        schemas = schema_search_path.split(/,/).map { |p| quote(p) }.join(',')
        query(<<-SQL, name).map { |row| row[0] }
          SELECT tablename
            FROM pg_tables
           WHERE schemaname IN (#{schemas})
        SQL
      end

      def indexes(table_name, name = nil) #:nodoc:
        result = query(<<-SQL, name)
          SELECT i.relname, d.indisunique, a.attname
            FROM pg_class t, pg_class i, pg_index d, pg_attribute a
           WHERE i.relkind = 'i'
             AND d.indexrelid = i.oid
             AND d.indisprimary = 'f'
             AND t.oid = d.indrelid
             AND t.relname = '#{table_name}'
             AND a.attrelid = t.oid
             AND ( d.indkey[0]=a.attnum OR d.indkey[1]=a.attnum
                OR d.indkey[2]=a.attnum OR d.indkey[3]=a.attnum
                OR d.indkey[4]=a.attnum OR d.indkey[5]=a.attnum
                OR d.indkey[6]=a.attnum OR d.indkey[7]=a.attnum
                OR d.indkey[8]=a.attnum OR d.indkey[9]=a.attnum )
          ORDER BY i.relname
        SQL

        current_index = nil
        indexes = []

        result.each do |row|
          if current_index != row[0]
            indexes << IndexDefinition.new(table_name, row[0], row[1] == "t", [])
            current_index = row[0]
          end

          indexes.last.columns << row[2]
        end

        indexes
      end

      def columns(table_name, name = nil) #:nodoc:
        column_definitions(table_name).collect do |name, type, default, notnull|
          Column.new(name, default_value(default), translate_field_type(type),
            notnull == "f")
        end
      end

      # Set the schema search path to a string of comma-separated schema names.
      # Names beginning with $ are quoted (e.g. $user => '$user')
      # See http://www.postgresql.org/docs/8.0/interactive/ddl-schemas.html
      def schema_search_path=(schema_csv) #:nodoc:
        if schema_csv
          execute "SET search_path TO #{schema_csv}"
          @schema_search_path = nil
        end
      end

      def schema_search_path #:nodoc:
        @schema_search_path ||= query('SHOW search_path')[0][0]
      end
            
      def add_column(table_name, column_name, type, options = {})
        native_type = native_database_types[type]
        sql_commands = ["ALTER TABLE #{table_name} ADD #{column_name} #{type_to_sql(type, options[:limit])}"]
        if options[:default]
          sql_commands << "ALTER TABLE #{table_name} ALTER #{column_name} SET DEFAULT '#{options[:default]}'"
        end
        if options[:null] == false
          sql_commands << "ALTER TABLE #{table_name} ALTER #{column_name} SET NOT NULL"
        end
        sql_commands.each { |cmd| execute(cmd) }
      end

      def change_column(table_name, column_name, type, options = {}) #:nodoc:
        execute = "ALTER TABLE #{table_name} ALTER  #{column_name} TYPE #{type}"
        change_column_default(table_name, column_name, options[:default]) unless options[:default].nil?
      end      

      def change_column_default(table_name, column_name, default) #:nodoc:
        execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET DEFAULT '#{default}'"
      end
      
      def rename_column(table_name, column_name, new_column_name) #:nodoc:
        execute "ALTER TABLE #{table_name} RENAME COLUMN #{column_name} TO #{new_column_name}"
      end

      def remove_index(table_name, options) #:nodoc:
        if Hash === options
          index_name = options[:name]
        else
          index_name = "#{table_name}_#{options}_index"
        end

        execute "DROP INDEX #{index_name}"
      end      

      
      private
        BYTEA_COLUMN_TYPE_OID = 17

        def last_insert_id(table, column = "id")
          sequence_name = "#{table}_#{column || 'id'}_seq"
          @connection.exec("SELECT currval('#{sequence_name}')")[0][0].to_i
        end

        def select(sql, name = nil)
          res = execute(sql, name)
          results = res.result           
          rows = []
          if results.length > 0
            fields = res.fields
            results.each do |row|
              hashed_row = {}
              row.each_index do |cel_index|
                column = row[cel_index]
                if res.type(cel_index) == BYTEA_COLUMN_TYPE_OID
                  column = unescape_bytea(column)
                end
                hashed_row[fields[cel_index]] = column
              end
              rows << hashed_row
            end
          end
          return rows
        end

        def escape_bytea(s)
          if PGconn.respond_to? :escape_bytea
            self.class.send(:define_method, :escape_bytea) do |s|
              PGconn.escape_bytea(s) if s
            end
          else
            self.class.send(:define_method, :escape_bytea) do |s|
              if s
                result = ''
                s.each_byte { |c| result << sprintf('\\\\%03o', c) }
                result
              end
            end
          end
          escape_bytea(s)
        end

        def unescape_bytea(s)
          if PGconn.respond_to? :unescape_bytea
            self.class.send(:define_method, :unescape_bytea) do |s|
              PGconn.unescape_bytea(s) if s
            end
          else
            self.class.send(:define_method, :unescape_bytea) do |s|
              if s
                result = ''
                i, max = 0, s.size
                while i < max
                  char = s[i]
                  if char == ?\\
                    if s[i+1] == ?\\
                      char = ?\\
                      i += 1
                    else
                      char = s[i+1..i+3].oct
                      i += 3
                    end
                  end
                  result << char
                  i += 1
                end
                result
              end
            end
          end
          unescape_bytea(s)
        end
        
        # Query a table's column names, default values, and types.
        #
        # The underlying query is roughly:
        #  SELECT column.name, column.type, default.value
        #    FROM column LEFT JOIN default
        #      ON column.table_id = default.table_id
        #     AND column.num = default.column_num
        #   WHERE column.table_id = get_table_id('table_name')
        #     AND column.num > 0
        #     AND NOT column.is_dropped
        #   ORDER BY column.num
        #
        # If the table name is not prefixed with a schema, the database will
        # take the first match from the schema search path.
        #
        # Query implementation notes:
        #  - format_type includes the column size constraint, e.g. varchar(50)
        #  - ::regclass is a function that gives the id for a table name
        def column_definitions(table_name)
          query <<-end_sql
            SELECT a.attname, format_type(a.atttypid, a.atttypmod), d.adsrc, a.attnotnull
              FROM pg_attribute a LEFT JOIN pg_attrdef d
                ON a.attrelid = d.adrelid AND a.attnum = d.adnum
             WHERE a.attrelid = '#{table_name}'::regclass
               AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY a.attnum
          end_sql
        end

        # Translate PostgreSQL-specific types into simplified SQL types.
        # These are special cases; standard types are handled by
        # ConnectionAdapters::Column#simplified_type.
        def translate_field_type(field_type)
          # Match the beginning of field_type since it may have a size constraint on the end.
          case field_type
            when /^timestamp/i    then 'datetime'
            when /^real|^money/i  then 'float'
            when /^interval/i     then 'string'
            when /^bytea/i        then 'binary'
            else field_type       # Pass through standard types.
          end
        end

        def default_value(value)
          # Boolean types
          return "t" if value =~ /true/i
          return "f" if value =~ /false/i
          
          # Char/String type values
          return $1 if value =~ /^'(.*)'::(bpchar|text|character varying)$/
          
          # Numeric values
          return value if value =~ /^[0-9]+(\.[0-9]*)?/

          # Date / Time magic values
          return Time.now.to_s if value =~ /^\('now'::text\)::(date|timestamp)/

          # Fixed dates / times
          return $1 if value =~ /^'(.+)'::(date|timestamp)/
          
          # Anything else is blank, some user type, or some function
          # and we can't know the value of that, so return nil.
          return nil
        end
    end
  end
end
