require 'mysql2/reconnect_with_readonly/version'
require 'mysql2'
require 'mysql2/client'

module Mysql2
  class ReconnectWithReadonly
    @reconnect_attempts  = 3
    @initial_retry_wait = 0.5
    @max_retry_wait  = nil
    @logger = nil

    class << self
      attr_accessor :reconnect_attempts, :initial_retry_wait, :max_retry_wait, :logger
    end

    def self.reconnect_with_readonly(client, &block)
      retries = 0
      begin
        yield block
      rescue Mysql2::Error => e
        # if e.message =~ Regexp.union(/Lost connection/, /gone away/, /read-only/, /Can't connect/, /MySQL client is not connected/, /Too many connections/)
        if e.message =~ Regexp.union(/read-only/, /Too many connections/)
          if retries < reconnect_attempts
            wait = initial_retry_wait * retries
            wait = [wait, max_retry_wait].min if max_retry_wait
            logger.info {
              "Reconnect with readonly: #{e.message} " \
              "(retries: #{retries}/#{reconnect_attempts}) (wait: #{wait}sec)"
            } if logger
            sleep wait
            retries += 1
            client.reconnect
            logger.debug { "Reconnect with readonly: disconnected and retry" } if logger
            retry
          else
            logger.info {
              "Reconnect with readonly: Give up " \
              "(retries: #{retries}/#{reconnect_attempts})"
            } if logger
            raise e
          end
        else
          raise e
        end
      end
    end

    OriginalClient = ::Mysql2::Client
    Mysql2.send(:remove_const, :Client)
  end
end

module Mysql2
  class Client
    class << self
      Mysql2::ReconnectWithReadonly::OriginalClient.methods(false).each do |method|
        define_method(method) do |*args|
          Mysql2::ReconnectWithReadonly::OriginalClient.send(method, *args)
        end
      end
    end

    Mysql2::ReconnectWithReadonly::OriginalClient.instance_methods(false).each do |method|
      define_method(method) do |*args|
        @original_client.send(method, *args)
      end
    end

    Mysql2::ReconnectWithReadonly::OriginalClient.constants.each do |const|
      const_set(const, Mysql2::ReconnectWithReadonly::OriginalClient.const_get(const))
    end

    def initialize(opts = {})
      @opts = opts
      @original_client = Mysql2::ReconnectWithReadonly::OriginalClient.new(@opts)
    end

    # Mysql2::Client does not have a #reconnect method
    # Mysql2::Client#close and Mysql2::Client#connect(*args) resulted in SEGV.
    # It is required to create a new Mysql2::Client instance for reconnection.
    # This is why we wrap orginal client with this monkey pathced client.
    def reconnect
      @original_client.close rescue nil
      @original_client = Mysql2::ReconnectWithReadonly::OriginalClient.new(@opts)
    end

    def query(sql, options = {})
      ReconnectWithReadonly.reconnect_with_readonly(self) do
        @original_client.query(sql, options)
      end
    end
  end
end
