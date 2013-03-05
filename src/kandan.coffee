# Hubot API
Robot        = require('hubot').Robot
Adapter      = require('hubot').Adapter
TextMessage  = require('hubot').TextMessage

# Node API
HTTP         = require('http')
EventEmitter = require('events').EventEmitter

# Faye connector
Faye         = require('faye')

class Kandan extends Adapter

  send: (envelope, strings...) ->
    if strings.length > 0
      callback = errback = (response) => @send envelope, strings...
      @bot.message strings.shift(), envelope.kandan?.channel?.id || 1, callback, errback

  run: ->
    options =
      host:     process.env.HUBOT_KANDAN_HOST
      port:     process.env.HUBOT_KANDAN_PORT || 80
      token:    process.env.HUBOT_KANDAN_TOKEN

    @bot = new KandanStreaming(options, @robot, @)
    callback = (myself) =>
      @bot.on "TextMessage", (message) =>
        unless myself.id == message.user.id
          envelope = @userForKandanUser(message.user)
          envelope.kandan.channel = message.channel
          @receive new TextMessage(envelope, message.content)
      @emit "connected"
    errback = (response) =>
      throw new Error "Unable to determine profile information."

    @bot.Me callback, errback

  userForKandanUser: (user) ->
    u = @userForId user.email, {
      email_address: user.email
    }
    # Note: Kandan values trump other adapters if brain is shared
    u.name = user.first_name + ' ' + user.last_name
    u.user = user.username
    u.kandan ?= {
      user: user
    }
    u

exports.use = (robot) ->
  new Kandan robot

class KandanStreaming extends EventEmitter
  constructor: (options, robot, adapter) ->
    @eventProcessors = {
      user: {}
      channel: {
        delete: (data) => @unsubscribe(data.entity.id)
        create: (data) => @subscribe(data.entity.id)
      }
      attachments: {}
    }

    unless options.token? and options.host?
      robot.logger.error "Not enough parameters provided. I need a host and token."
      process.exit(1)

    @host     = options.host
    @port     = options.port
    @token    = options.token

    @logger = robot.logger
    @adapter = adapter

    target = "http://#{ @host }:#{ @port }/remote/faye"
    robot.logger.info("Connecting to #{ target }")

    @client = new Faye.Client(target)
    @client.disable('websocket')
    authExtension = {
      outgoing: (message, callback) =>
        if message.channel == "/meta/subscribe"
          message['ext'] = { auth_token: @token }
        callback(message)
    }
    @client.addExtension(authExtension)

    @client.bind "transport:up", () =>
      robot.logger.info "Connected to Faye server"

    @client.bind "transport:down", () =>
      robot.logger.error "Disconnected from Faye server"

    @subscribeEvents()
    @subscribeChannels()
    robot.brain.on 'loaded', @syncUsers
    @

  warner: (message) ->
    (err) => @logger.warn "#{message} #{if err then "(#{err})"}"

  syncUsers: =>
    return if @_synced == true
    callback = (users) =>
      @_synced = true
      @adapter.userForKandanUser(user) for user in users
    @Users callback, @warner("Error retrieving users; unable to synchronize user list")

  subscribeChannels: ->
    # Always subscribe to the primary channel
    @subscribe(1)
    # Subscribe to all the other channels
    callback = (channels) =>
      for channel in channels
        @subscribe(channel.id) unless channel.id == 1
    @Channels callback, @warner("Error retrieving channels list; will only listen on primary channel")

  subscribeEvents: ->
    @client.subscribe "/app/activities", (data) =>
      @logger.debug "Had events: #{JSON.stringify(data)}"
      [entityName, eventName] = data.event.split("#")
      @eventProcessors[entityName]?[eventName]?(data)

  unsubscribe: (channelId) ->
    @logger.debug "Unsubscribing from channel: #{channelId}"
    @client.unsubscribe "/channels/#{channelId}"

  subscribe: (channelId) ->
    @logger.debug "Subscribing to channel: #{channelId}"
    subscription = @client.subscribe "/channels/#{channelId}", (activity) =>
      eventMap =
        'enter':   'EnterMessage'
        'leave':   'LeaveMessage'
        'message': 'TextMessage'
      @emit eventMap[activity.action], activity
    subscription.errback((activity) =>
      @logger.error activity
      @logger.error "Oops! could not connect to the server"
    )

  message: (message, channelId, callback, errback) ->
    body = {
      content: message
      channel_id: channelId
      activity: {
        content: message,
        channel_id: channelId,
        action: "message"
      }
    }
    @post "/channels/#{ channelId }/activities", body, callback, errback

  Channels: (callback, errback) ->
    @get "/channels", callback, errback

  User: (id, callback, errback) ->
    @get "/users/#{id}", callback, errback

  Users: (callback, errback) ->
    @get "/users", callback, errback

  Me: (callback, errback) ->
    @get "/users/me", callback, errback

  Channel: (id) =>
    logger = @logger

    show: (callback, errback) ->
      @post "/channels/#{id}", "", callback, errback

    join: (callback, errback) ->
      logger.info "Join is a NOOP on Kandan right now"

    leave: (callback, errback) ->
      logger.info "Leave is a NOOP on Kandan right now"


  get: (path, callback, errback) ->
    @request "GET", path, null, callback, errback

  post: (path, body, callback, errback) ->
    @request "POST", path, body, callback, errback

  request: (method, path, body, callback, errback) ->
    logger = @logger

    headers =
      "Content-Type" : "application/json"
      "Accept"       : "application/json"

    options =
      "agent"   : false
      "host"    : @host
      "port"    : @port
      "path"    : path
      "method"  : method
      "headers" : headers

    if method is "POST" || method is "PUT"
      body.auth_token = @token
      if typeof(body) isnt "string"
        body = JSON.stringify(body)

      body = new Buffer(body)
      options.headers["Content-Length"] = body.length
    else
      options.path += "?auth_token=#{@token}"

    request = HTTP.request options, (response) ->
      data = ""

      response.on "data", (chunk) ->
        data += chunk

        response.on "end", ->
          if response.statusCode >= 400
            switch response.statusCode
              when 401
                throw new Error "Invalid access token provided, Kandan refused the authentication"
              else
                logger.error "Kandan error: #{response.statusCode}"
            errback(response) if errback?
            return

          try
            callback JSON.parse(data) if callback?
          catch err
            console.log err
            errback(err) if errback?

    if method is "POST" || method is "PUT"
      request.end(body, 'binary')
    else
      request.end()

    request.on "error", (err) ->
      logger.error "Kandan request error: #{err}"
      errback(response) if errback?
