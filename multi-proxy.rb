$:<< '../lib' << 'lib'

require 'em-proxy'
require 'ansi/code'
require 'uri'
require 'json'
require 'net/http'
require 'uuid'
require 'http/parser'


$:.unshift '.'


$coinSymbol="LTC"

module StratumMultiProxy
  extend self

  BACKENDS = [
    {:url => "http://127.0.0.1:16001"},
    {:url => "http://127.0.0.1:16002"}
  ]

  class Backend

    attr_reader   :url, :host, :port
    attr_accessor :load
    alias         :to_s :url

    def initialize(options={})
      raise ArgumentError, "Please provide a :url and :load" unless options[:url]
      @url   = options[:url]
      @load  = options[:load] || 0
      parsed = URI.parse(@url)
      @host, @port = parsed.host, parsed.port
    end

    # Select backend: balanced, round-robin or random
    #
    def self.select(coin = :LTC)
      @coin = coin.to_sym
      case @coin
      when :LTC
        backend = list[0]
      when :DGC
        backend = list[1]
      else
        raise ArgumentError, "Unknown coin: #{@coin}"
      end

      Callbacks.on_select.call(backend)
      yield backend if block_given?
      backend
    end

    # List of backends
    #
    def self.list
      @list ||= BACKENDS.map { |backend| new backend }
    end

    # Return coin
    #
    def self.coin
      @coin
    end

    # Increment "currently serving requests" counter
    #
    def increment_counter
      self.load += 1
    end

    # Decrement "currently serving requests" counter
    #
    def decrement_counter
      self.load -= 1
    end

  end

  # Callbacks for em-proxy events
  #
  module Callbacks
    include ANSI::Code
    extend  self

    def on_select
      lambda do |backend|
        puts black_on_white { 'on_select'.ljust(12) } + " #{backend.inspect}"
      end
    end

    def on_connect
      lambda do |backend|
        puts black_on_magenta { 'on_connect'.ljust(12) } + ' ' + bold { backend }
      end
    end

    def on_data
      lambda do |raw|
        response = ''
        # raw can have multiple json objects separated by \n
        responses = raw.split "\n"

        responses.each do |r|
          if r =~ /mining.submit/ or r =~ /mining.authorize/
            begin
              data = JSON.parse r, :quirks_mode => true
            rescue
              puts "mining submit parse_error,#{r}"
              response += r
            else
              if data["method"] == 'mining.submit'
                # if we have a submission, move address to id in the format <id>-<address>
                address = data["params"][0]
                id = data["id"]
                data['id'] = "#{id}-#{address}"
                # add our address
                data["params"][0] = address
                # add submission to pending
                Submission.new(address, id)
                # add modified response as json string
                response += JSON.dump(data)
              elsif data["method"] == 'mining.authorize'
                authWorker=data["params"][0].gsub(".","/")

                begin
                  authResponse = Net::HTTP.get_response("dev.manicminer.in","/api/check/worker/#{authWorker}.json")

                rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
                    Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e

                  puts "Error en workername"
                end

                begin
                  authBody= JSON.parse authResponse.body
                rescue Exception => e
                  puts "Error en worker"
                  authBody = '{"OK = false }'
                end

                #puts authBody
                authCoin=authBody['coin']
                if (authBody["ok"] == true && $coinSymbol == authCoin)
                  begin
                    data["params"][0] = authWorker.gsub("/",".")
                    
                    #puts "Login OK"
                  end
                else
                  response = "ERROR"
                end

                response += JSON.dump(data)
                #puts (JSON.dump(data))
              end
            end
          else
            response += r
          end
          response += "\n"
        end

        response
      end

    end

    def on_response
      lambda do |backend, raw|
        response = raw.dup

        # check if response in a reply to a share submission
        has_submission = false
        Submission.pending.each do |s|
          if raw =~ /#{s}/
            has_submission = true
            break
          end
        end

        if raw =~ /set_difficulty/
          #puts(raw)
          raw.split("\n").each do |r|
            #raw.each do |r|
            if r =~ /set_difficulty/
              begin
                data = JSON.parse(r, :quirks_mode => true)
                Submission.set_target(data['params'][0])
                #puts(data)
              rescue
                puts "set difficulty parse_error,#{r}"

              end
            end
          end
        end

        # if we found a submission or we have a difficulty adjustment
        if has_submission
          # response can contain multiple json objects, split on \n
          response = ''
          responses = raw.split "\n"

          # check each response for a share submission response
          responses.each do |r|
            found_submission = false

            # if the response is a difficulty request, record it
            if r =~ /result/
              begin
                data = JSON.parse(r, :quirks_mode => true)
              rescue
                puts "result parse_error,#{r}"
              else
                if Submission.pending.include?(data['id'])
                  # remove the share from the list and record the result
                  Submission.finalize(data['id'], data['result'])
                  id, address = data['id'].split '-'
                  # restore original id
                  data['id'] = id
                  # dump data back to string
                  response += JSON.dump(data)
                  found_submission = true
                end
              end
            end

            # if no submission was found for this response, just copy it intact
            unless found_submission
              response += r
            end

            response += "\n"
          end
        end
        response
      end
    end

    def on_finish
      lambda do |backend|
        puts black_on_cyan { 'on_finish'.ljust(12) } + " for #{backend}", ''
      end
    end

  end

  # Wrapping the proxy server
  #
  module Server
    def run(host='0.0.0.0', port=9999)

      puts ANSI::Code.bold { "Launching proxy at #{host}:#{port}...\n" }

      Proxy.start(:host => host, :port => port, :debug => false) do |conn|

        Backend.select( $coinSymbol )  do |backend|
          puts ANSI::Code.bold { "connecting backend at #{backend.host}:#{backend.port}...\n" }
          conn.server backend, :host => backend.host, :port => backend.port

          conn.on_connect  &Callbacks.on_connect
          conn.on_data     &Callbacks.on_data
          conn.on_response &Callbacks.on_response
          conn.on_finish   &Callbacks.on_finish
        end
      end
    end

    module_function :run
  end

end



module ShareLogger
  def self.start
    @@run = true
    @@lock = Mutex.new
    @@messages ||= []
    @@thread = Thread.new do
      while @@run
        temp = nil
        @@lock.synchronize do
          temp = @@messages
          @@messages = []
        end

        #puts "Entrando en Thread Enviando share #{temp}"
        temp.each do |share|
          #puts "Thread Enviando share #{share}"

          begin
            authResponse = Net::HTTP.get_response("dev.manicminer.in",share)

          rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
              Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e

            puts "Error Enviando share #{share}"
          end
        end
        sleep 5
      end
    end
    self
  end

  def self.queue_message(msg)
    @@lock.synchronize do
      @@messages << msg
    end
  end

  def self.stop
    @@run = false
  end
end

class Submission
  def initialize(address, id)
    @@target ||= 1
    @@logger ||= ShareLogger.start
    @@submissions ||= []
    worker=address.gsub(".","/")
    @@submissions << "#{id}-#{address}"

    # record submission
    @@logger.queue_message "/api/submit/#{@@target}/#{worker}/#{$coinSymbol}/#{id}.json"
  end

  def self.pending
    @@submissions ||= []
    @@submissions.dup
  end

  def self.finalize(id, valid)
    # mark submission as completed or not
    @@submissions.delete(id)
    orig_id, address = id.split '-'
    worker=address.gsub(".","/")
    @@logger.queue_message "/api/result/#{@@target}/#{Time.now.utc.to_i}/#{worker}/#{$coinSymbol}/#{orig_id}/#{valid}.json"
  end

  def self.set_target(target)
    @@target = target
  end
end


if __FILE__ == $0


  class Proxy
    def self.stop
      puts "Terminating ProxyServer"
      EventMachine.stop
    end
  end

  # Start proxy
  StratumMultiProxy::Server.run

end
