module ShareLogger
  def self.start
    @@run = true
    @@lock = Mutex.new
    @@messages ||= []
    @@thread = Thread.new do
      open("shares.log", "a") do |l|
        while @@run
          temp = nil
          @@lock.synchronize do
            temp = @@messages
            @@messages = []
          end
          l.puts(temp.join("\n")) unless temp.empty?
          l.flush
          sleep 5
        end
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
