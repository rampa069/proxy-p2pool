require 'json'
require 'em-proxy'

$:.unshift '.'

require 'share_logger'

POOL_ADDRESS = "1B1kSM3KfcP9BvGDC1G3cxZAV9LbxovpQi"

class Submission
  def initialize(address, id)
    @@target ||= 1
    @@logger ||= ShareLogger.start
    @@submissions ||= []
    @@submissions << "#{id}-#{address}"
    # record submission
    @@logger.queue_message "submit,#{target},#{address},#{id}"
  end

  def self.pending
    @@submissions ||= []
    @@submissions.dup
  end

  def self.finalize(id, valid)
    # mark submission as completed or not
    @@submissions.delete(id)
    orig_id, address = id.split '-'
    @@logger.queue_message "result,#{target},#{address},#{orig_id},#{valid}"
  end

  def self.set_target(target)
    @@target = target
  end
end

Proxy.start(:host => "0.0.0.0", :port => 9339) do |conn|
  conn.server :srv, :host => "127.0.0.1", :port => 9332

  # modify / process request stream
  conn.on_data do |raw|
    response = ''
    # raw can have multiple json objects separated by \n
    responses = raw.split "\n"

    responses.each do |r|
      if r =~ /mining.submit/
        data = JSON.parse r, :quirks_mode => true
        # if we have a submission, move address to id in the format <id>-<address>
        address = data["params"][0]
        id = data["id"]
        data['id'] = "#{id}-#{address}"
        # add our address
        data["params"][0] = POOL_ADDRESS
        # add submission to pending
        Submission.new(address, id)
        # add modified response as json string
        response += JSON.dump(data)
      else
        response += r
      end
      response += "\n"
    end

    response.tap {|x| puts x}
  end

  # modify / process response stream
  conn.on_response do |backend, raw|
    response = raw.dup

    # check if response in a reply to a share submission
    has_submission = false
    Submission.pending.each do |s|
      if raw =~ /#{s}/
        has_submission = true
        break
      end
    end

    # if we found a submission or we have a difficulty adjustment
    if has_submission or raw =~ /set_difficulty/
      # response can contain multiple json objects, split on \n
      response = ''
      responses = raw.split "\n"

      # check each response for a share submission response
      responses.each do |r|
        found_submission = false

        # if the response is a difficulty request, record it
        if r =~ /set_difficulty/
          data = JSON.parse(r, :quirks_mode => true)
          Submission.set_target(data['params'][0])
        elsif has_submission and r =~ /result/
          data = JSON.parse(r, :quirks_mode => true)
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
        
        # if no submission was found for this response, just copy it intact
        unless found_submission
          response += r
        end
        
        response += "\n"
      end
    end
    p [raw, response] if raw =~ /result/
    response
  end

  # termination logic
  conn.on_finish do |backend, name|
    #    p [:on_finish, name]
    
    # terminate connection (in duplex mode, you can terminate when prod is done)
    unbind if backend == :srv
  end
end
