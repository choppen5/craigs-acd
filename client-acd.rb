require 'rubygems'
require 'sinatra'
require 'sinatra/config_file' #Config
require 'twilio-ruby'
require 'json'
require 'sinatra'
require 'sinatra-websocket'
require 'pp'
require 'yaml'
require 'thread'

sockets_semaphore, userlist_semaphore, calls_semaphore = Mutex.new, Mutex.new, Mutex.new

config_file 'config_file.yml'

set :server, 'thin'
set :sockets, []

disable :protection


############ CONFIG ###########################
# Find these values at twilio.com/user/account
account_sid = settings.account_sid
auth_token =  settings.auth_token
app_id = settings.app_id

# put your default Twilio Client name here, for when a phone number isn't given
default_client = settings.default_client
caller_id = settings.caller_id  #number your agents will click2dialfrom

queue_id = settings.queue_id  #hardcoded! need to return a queue by friendly name..

#new setting
qname = settings.queue_name

dqueueurl = settings.dqueueurl


@client = Twilio::REST::Client.new(account_sid, auth_token)


################ ACCOUNTS ################

# shortcut to grab your account object (account_sid is inferred from the client's auth credentials)
@account = @client.account
@queues = @account.queues.list
#puts "queues = #{@queues}"

#hardcoded queue... change this to grab a configured queue

queueid = nil
@queues.each do |q|
  puts "q = #{q.friendly_name}"
  if q.friendly_name == qname
    queueid = q.sid
    puts "found #{queueid} for #{q.friendly_name}"
  end
end

unless queueid
  #didn't find queue, create it
  @queue = @account.queues.create(:friendly_name => qname)
  puts "created queue #{qname}"
  queueid = @queue.sid
 end

 puts "queueid = #{queueid}"

queue1 = @account.queues.get(queueid)

userlist = {}   # All users, in memory
calls = {}   # Tracked calls, in memory

# activeusers = 0   # Calculated from userlist

$sum = 0

# Has utility methods for now.  Eventually make this be the sinatra class.
class ClientAcd

  @@whitelist, @@whitelist_candidates = nil, []

  def self.whitelist_candidates
    @@whitelist_candidates
  end

  def self.whitelist= val
    @@whitelist = val
  end
  def self.whitelist
    @@whitelist ||= YAML::load(File.read "whitelist.yml")
    @@whitelist
  end
end

# Start loop to check Twilio etc...

EM::next_tick do
  EventMachine.run do
    EM.add_periodic_timer(1.0) do

      begin
        $sum += 1

        puts "printing user list..."
        print(userlist.map do |name, hash|
          string = hash.map{|k, v| "#{k.inspect}=>#{v.is_a?(SinatraWebsocket::Connection) ? '<Socket>' : v.inspect}"}.join(", ")
          "  - #{name}: #{string}"
        end.join("\n"))

        first = 0
        callerinqueue = false
        qsize = 0
        @members = queue1.members
        @members.list.each do |m|
          qsize +=1
          puts "Sid: #{m.call_sid}"
          puts "Date Enqueue: #{m.date_enqueued}"
          puts "Wait_Time: #{m.wait_time} "
          puts "Position: #{m.position}"
          if first == 0
            first = m
            callerinqueue = true
          end
        end

        puts "qsize = #{qsize}"

        if callerinqueue #only check for route if there is a queue member
          bestclient = getlongestidle(userlist)
          if bestclient == "NoReadyAgents"
            #nobody to take the call... should redirect to a queue here
            puts "No ready agents.. keeq waiting...."
          else
            puts "Found availible agent =  #{bestclient[0]}"
            first.dequeue(dqueueurl)
            #get clients phone number, if any
          end
        end

        # Send updated counts to each client...

        readycount = userlist.select{|key, hash| hash[:status] == "Ready"}.length

        settings.sockets.each{|s|
          msg = {:queuesize => qsize, :readyagents => readycount}.to_json
          puts "sending #{msg}"
          s.send(msg)
        }

        # TODO: guard against thread death - maybe wrap in rescue?

        #puts "average queue wait time: #{queue1.average_wait_time}"
        #puts "queue depth = #{queue.depth}"
        puts "run = #{$sum} #{Time.now}"
      rescue
        puts "error in thread loop"
        puts $!, $@
      end
    end
  end
end

get '/token' do
  client_name = params[:client]
  if client_name.nil?
        client_name = default_client
  end
  capability = Twilio::Util::Capability.new account_sid, auth_token
  # Create an application sid at twilio.com/user/account/apps and use it here
  capability.allow_client_outgoing app_id
  capability.allow_client_incoming client_name
  token = capability.generate
  return token
end

get '/' do
  #for hmtl client
  client_name = params[:client]
  if client_name.nil?
        client_name = default_client
  end

  erb :index, :locals => {}
end

get '/websocket' do

  request.websocket do |ws|
    ws.onopen do
      puts ws.object_id
      querystring = ws.request["query"]
      # query should be something like wsclient=coppenheimerATvccsystemsDOTcom

      clientname = params[:clientname]

      user = userlist[clientname]

      if user
        #removed, don't set user status in websocket connection
        #user[:status] = " "
        user[:activity] = Time.now.to_f
        user[:count] ||= 0;  user[:count] += 1
        user[:socket] = ws
        # Phone number stays the same
      else
        #user didn't exist, create them
        userlist_semaphore.synchronize {
          userlist[clientname] = {:status=>" ", :activity=>Time.now.to_f, :count=>1, :socket=>ws}
        }
      end

      sockets_semaphore.synchronize {
        settings.sockets << ws
      }

      number = userlist[clientname][:phone]

      # Each time we open the socket, give it the field values to repaint
      msg = {:do=>'paint', :agent_number_entry=>number}.to_json

      ws.send msg

    end

    ws.onclose do

      begin
        querystring = ws.request["query"]

        clientname = params[:clientname]

        settings.sockets.delete(ws)

        user = userlist[clientname]
        user[:count] -= 1

        # if not more clients are registered, set to not ready
        if user[:count] < 1
          #don't do this... if a user loggs out in ready mode, we will still send them calls.  decide on rules around this....

          #user[:status] = "LOGGEDOUT"
          #user[:activity] = Time.now
        end

      #remove client count

      rescue
        puts $!, $@
      end

    end
  end

end


#
# For incoming voice calls, from twilio...
# Not for client to client routing (move that elsewhere).
#
post '/voice' do

  puts "params = #{params}"

  number = params[:PhoneNumber]
  sid = params[:CallSid]
  queue_name = params[:queue_name]
  requestor_name = params[:requestor_name]
  message = params[:message]

  callerid = params[:Caller]
  #if special parameter requesting_party is passed, make it the caller id
  if params[:requesting_party]
    callerid = params[:requesting_party]
  elsif params[:Direction] == "outbound-api" #special case when call queued from a outbound leg
    callerid = params[:To]
  end

  #capture call data
  if calls[sid]
    puts "found sid #{sid} = #{calls[sid]}"
  else
    puts "creating sid #{sid}"
    calls_semaphore.synchronize { calls[sid] = {} }
    calls[sid][:queue_name] = queue_name
    calls[sid][:requestor_name] = requestor_name
    calls[sid][:message] = message
  end

  bestclient = getlongestidle(userlist)

  if bestclient == "NoReadyAgents"
    #nobody to take the call... should redirect to a queue here
    dialqueue = qname
  else
    puts "Found best agent! #{bestclient[0]}"
    agent_name = bestclient[0]
    #get clients phone number, if any
  end

  #if no client is choosen, route to queue



  response = Twilio::TwiML::Response.new do |r|

    if dialqueue  #no agents avalible
      r.Say("Please wait for the next available agent ")
      r.Enqueue(dialqueue)
      #r.Redirect('/wait')
    else      #send to best agent
      r.Dial(:timeout=>"18", :action=>"/handleDialCallStatus", :callerId => callerid) do |d|

        calls[sid][:agent] = agent_name
        calls[sid][:status] = "Ringing"
        userlist[agent_name][:status] = "Inbound"
        userlist[agent_name][:inbound_number] = params[:From]

        puts "dialing client #{agent_name}"

        # Send websocket message to client to do screen pop...

        socket = bestclient[1][:socket]

        msg = {:do=>"screenpop", :From=>params[:From]}.to_json

        puts "sending #{msg}"
        socket.send(msg)

        # Respond to twilio to call the agent's number...

        d.Number bestclient[1][:phone]

      end
    end
  end
  puts "response text = #{response.text}"
  response.text
end


# Twillio calls this when hung up

post '/handleDialCallStatus' do

  #where calls go to die.  Actually after dying. The ghost of a call if youw
  puts "HANDLEDIALCALLSTATUS params = #{params}"

  sid = params[:CallSid]
  puts calls # variable for tracking calls... {"CAcb90adcb68b6e51b96d8216d105ff645"=>{:client=>"defaultclient", :status=>"Ringing", "status"=>"Missed"}}

  agent = calls[sid][:agent]  #get the agent for this call

  response = Twilio::TwiML::Response.new do |r|

      #consider logging all of this?
      if params['DialCallStatus'] != "completed"

        calls[sid][:status] = "Missed"
        userlist[agent][:status] = "Missed"
        #the agent did not accept the call, so send it back to the next agent
        r.Redirect('/voice')
      else
        #they completed a call, so go back to ready. this may need to be changed to go to not ready or After Call Work mode. meantime, agents finish a call and are immediatly ready.
        userlist[agent][:status] = "Ready"
      end

      #send a message to this badboy.
      socket = userlist[agent][:socket]
      msg = {:do=>"paint", :status=>userlist[agent][:status]}.to_json

      puts "sending #{msg}"
      socket.send(msg)

  end
  puts "handlecall status response.text  = #{response.text}"
  response.text
end

### ACD stuff - for tracking agent state
get '/track' do

  begin

    from = params[:from]
    status = params[:status]
    agent_number = params[:agent_number]
    currentclientcount = 0

    # Validate against the whitelist if going ready

    if status == "Ready" && ! ClientAcd.whitelist.member?(agent_number.gsub(/\W/, ''))
      ClientAcd.whitelist_candidates << agent_number
      ClientAcd.whitelist_candidates.uniq!
      return {:result=>:failure, :message=>"Adding phone number to the whitelist. Needs approval."}.to_json
    end

    #check if this guy is already registered as a client from another webpage
    if userlist.has_key?(from)
      currentclientcount = userlist[from][:count]
    end

    #update the userlist{} status.. this is now his status
    puts "For client #{from} retrieved currentclientcount = #{currentclientcount} and setting status to #{status}"

    # Pass socket along (must already by there)
    user = userlist[from]
    socket = user[:socket] if user

    userlist_semaphore.synchronize {
      userlist[from] = {:status=>status, :activity=>Time.now.to_f, :count=>currentclientcount, :socket=>socket, :phone=>agent_number}
    }

    puts(userlist.map do |name, hash|
      string = hash.map{|k, v| "#{k.inspect}=>#{v.is_a?(SinatraWebsocket::Connection) ? '<Socket>' : v.inspect}"}.join(", ")
      "  - #{name}: #{string}"
    end.join("\n"))

    readycount = userlist.select{|key, hash| hash[:status] == "Ready"}.length

    p "Number of users #{userlist.length}, number of readyusers = #{readycount}, currentclientcount = #{currentclientcount}"

  rescue
    puts $!, $@
  end

  {:result=>:success}.to_json

end

get '/status' do
  #returns status for a particular client
  from = params[:from]
  p "from #{from}"
  #grab the first element in the status array for this user ie, [\"Ready\", 1376194403.9692101]"

  if userlist.has_key?(from)
    user = userlist[from]
    status = {
      :status=>user[:status],
      :phone=>user[:phone],
      :inbound_number=>user[:inbound_number],
      :customer_number=>user[:customer_number],
    }.to_json
    p "status = #{status}"
  else
    status ="no status"
  end
  return status
end


def getlongestidle(userlist)

  readyusers = userlist.select{|key, hash| hash[:status] == "Ready"}

  if readyusers.count < 1
    return "NoReadyAgents"
  end

  sorted = readyusers.sort_by{|name, hash|
    hash[:activity]
  }

  sorted.first   # Lowest time of last activity is longest idle
end


get '/calldata' do
  #sid will be a client call, need to get parent for attached data
  sid = params[:CallSid]

  @client = Twilio::REST::Client.new(account_sid, auth_token)
  @call = @client.account.calls.get(sid)

  parentsid = @call.parent_call_sid
  puts "parent sid for #{sid} = #{parentsid}"

  calldata = calls[@call.parent_call_sid]

  #puts "calls sid = #{calls[sid]}"

  if calls[parentsid]
    msg = { :agentname => calldata[:agent], :agentstatus => calldata[:status], :queue_name => calldata[:queue_name], :requestor_name => calldata[:requestor_name], :message => calldata[:message]}.to_json
  else
    msg = "NoSID"
  end

  return msg

end

## requests from mobile application to initiate PSTN callback
post '/mobile-call-request' do

  # todo change parameter names on mobile device to match
  requesting_party = params[:phone_number]
  queue_name = params[:queue]
  requestor_name = params[:name]
  message = params[:message]


  url = request.base_url
  unless request.base_url.include? 'localhost'
     url = url.sub('http', 'https')
  end
  puts "mobile call request url = #{url}"

  @client = Twilio::REST::Client.new(account_sid, auth_token)
  # outbound PSTN call to requesting party. They will be call screened before being connected.
  @client.account.calls.create(:from => caller_id, :to => requesting_party, :url => URI.escape("#{url}/connect-mobile-call-to-agent?queue_name=#{queue_name}&requestor_name=#{requestor_name}&requesting_party=#{requesting_party}&message=#{message}"))


  return ""

end


post '/connect-mobile-call-to-agent' do

  requesting_party = params[:requesting_party]
  queue_name = params[:queue_name]
  requestor_name = params[:requestor_name]
  message = params[:message]
  callerid = params[:to]

  response = Twilio::TwiML::Response.new do |r|

    # call screen
    r.Pause "1"
    r.Gather(:action => URI.escape("/voice?requesting_party=#{requesting_party}&queue_name=#{queue_name}&requestor_name=#{requestor_name}&message=#{message}&requesting_party=#{requesting_party}"), :timeout => "10", :numDigits => "1") do |g|
      g.Say("Press any key to speak to an agent now.")
    end

    # no key was pressed
    r.hangup

    return r.text

  end

end

get '/clicktodial' do
  agentname = params[:agent]
  agentnumber = params[:agentnumber]
  customernumber = params[:customernumber]


  @client = Twilio::REST::Client.new(account_sid, auth_token)

  #first, call agent
  url = request.base_url
  unless request.base_url.include? 'localhost'
     url = url.sub('http', 'https')
  end

  @call = @client.account.calls.create(:from=>caller_id, :to=>agentnumber, :url => URI.escape("#{url}/connectagenttocustomer?customernumber=#{customernumber}&agentnumber=#{agentnumber}"))
  #todo: add this caller sid and agent status.. ie he is on a click2dial
  sid = @call.sid
  puts "Sid for click2dial = #{sid}"
  userlist[agentname][:status] = "Outbound"
  userlist[agentname][:customer_number] = customernumber

  calls_semaphore.synchronize { calls[sid] = {} }
  calls[sid][:agent] = agentname
  calls[sid][:status] = "Outbound"

  #websocket message for this agent here...

end

post '/connectagenttocustomer' do

  puts "connecting agent to customer..."

  agentnumber = params[:agentnumber]
  customernumber = params[:customernumber]


  response = Twilio::TwiML::Response.new do |r|
    params[:customersnumber]
    #this will happen after agent gets the call
    r.Dial(:timeout=>"10", :action=>"/handleDialCallStatus", :callerId=>settings.caller_id) do |d|
      d.Number customernumber
    end

    return r.text
  end

end

def authorized?
  @auth ||=  Rack::Auth::Basic::Request.new(request.env)
  @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == ["dashboard","dash^w^yAll"]
end

def protected!
  unless authorized?
    response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
    throw(:halt, [401, "Oops... we need your login name & password\n"])
  end
end

get '/dashboard/add' do
  protected!

  number = params[:number]
  list = YAML::load(File.read("whitelist.yml"))
  list << number.gsub(/\W/, '')
  File.open("whitelist.yml", "w") { |f| f << list.to_yaml }
  ClientAcd.whitelist = nil
  ClientAcd.whitelist_candidates.delete(number)
  {:result=>:success}.to_json
end

get '/dashboard/remove' do
  protected!

  name = params[:name]
  userlist_semaphore.synchronize {
    userlist.delete name
  }

  {:result=>:success}.to_json
end

get %r{/dashboard/?} do

  protected!

  #   userlist = {
  #     "craigDOTmuthATcohealthop.org"=>{:status=>"Ready", :activity=>1380580967.7546318, :phone=>"5132882013", :customer_number=>"4155773411"},
  #     "steve"=>{:status=>"Planking", :activity=>1380580967.7546318, :phone=>"5132882013", :customer_number=>"4155773411"},
  #   }

  rows =
    userlist.sort_by{|key, val| -val[:activity]}#.map do |name, hash|

  erb :dashboard, :locals => {
    :rows=>rows,
    :whitelist=>ClientAcd.whitelist,
    :whitelist_candidates=>ClientAcd.whitelist_candidates,
  }

end
