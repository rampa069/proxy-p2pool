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
