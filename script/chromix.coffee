#!/usr/bin/env node

# #####################################################################
# Imports, arguments and constants.

WebSocket = require "ws"
conf      = require "optimist" 
conf      = conf.usage "Usage: $0 [--port=PORT] [--server=SERVER]" 
conf      = conf.default "port", 7441 
conf      = conf.default "server", "localhost" 
conf      = conf.default "timeout", "500" 
conf      = conf.argv

chromi    = "chromi"
chromiCap = "Chromi"

# #####################################################################
# Utilities.

json = (x) -> JSON.stringify x

echo = (msg, where = process.stdout) ->
  switch typeof msg
    when "string"
      # Do nothing.
      true
    when "list"
      msg = msg.join " "
    else
      msg = json msg
  where.write "#{msg}\n"

echoErr = (msg, die = false) ->
  echo msg, process.stderr
  process.exit 1 if die

# #####################################################################
# Tab selectors.
#
# The main method here is `fetch` which takes a `pattern` and yields a predicate function for testing
# window/tab pairs against that pattern.  `Selector` also serves as a cache for regular expressions.
#
class Selector
  selector: {}

  fetch: (pattern) ->
    return @selector[pattern] if @selector[pattern]
    regexp = new RegExp pattern
    @selector[pattern] =
      (win,tab) ->
        win.type == "normal" and regexp.test tab.url

  constructor: ->
    @selector.window   = (win,tab) -> win.type == "normal"
    @selector.all      = (win,tab) -> win.type == "normal" and true
    @selector.active   = (win,tab) -> win.type == "normal" and tab.active
    @selector.current  = (win,tab) -> win.type == "normal" and tab.active
    @selector.other    = (win,tab) -> win.type == "normal" and not tab.active
    @selector.inactive = (win,tab) -> win.type == "normal" and not tab.active
    @selector.normal   = @fetch "https?://"
    @selector.http     = @fetch "https?://"
    @selector.file     = @fetch "file://"

selector = new Selector()

# #####################################################################
# Web socket utilities.
#
# A single instance of the `WS` class is the only interface to the websocket.  The websocket connection is
# cached.
#
# For external use, the main method here is `do`.

class WS
  constructor: ->
    @queue = []
    @ready = false
    @callbacks = {}
    @ws = new WebSocket "ws://#{conf.server}:#{conf.port}/"

    @ws.on "error",
      (error) ->
        echoErr json(error), true

    @ws.on "open",
      =>
        # Process any queued requests.  Subsequent requests will not be queued.
        @ready = true
        for callback in @queue
          callback()

    # Handle an incoming message.
    @ws.on "message",
      (msg) =>
        msg = msg.split(/\s+/)
        [ signal, msgId, type, response ] = msg
        # Is the message for us?
        return unless signal == chromiCap and @callbacks[msgId]
        switch type
          when "info"
            # Quietly ignore these.
            true
          when "done"
            @callback msgId, response
          when "error"
            @callback msgId
          else
            echoErr msg

  # Send a request to chrome.
  # If the websocket is already connected, then the request is sent immediately.  Otherwise, it is cached
  # until the websocket's "open" event fires.
  send: (msg, callback) ->
    id = @createId()
    f = =>
      @register id, callback
      @ws.send "#{chromi} #{id} #{msg}"
    if @ready then f() else @queue.push f

  register: (id, callback) ->
    # Add `callback` to a dict of callbacks hashed on their request `id`.
    #
    # Timeouts are never cancelled.  If the request has successfully completed by the time the timeout fires,
    # the callback will already have been removed from the list of callbacks (so it's safe).
    setTimeout ( => @callback id ), conf.timeout
    @callbacks[id] = callback

  # Invoke the callback for the indicated request `id`.
  callback: (id, argument=null) ->
    if @callbacks[id]
      callback = @callbacks[id]
      delete @callbacks[id]
      callback argument

  # `func`: a string of the form "chrome.windows.getAll"
  # `args`: a list of arguments for `func`
  # `callback`: will be called with the response from chrome; the response is `undefined` if the invocation
  #             failed in any way; see the chromi server's output to trace what may have gone wrong.
  do: (func, args, callback) ->
    msg = [ func, json args ].map(encodeURIComponent).join " "
    @send msg, (response) ->
      if callback
        callback.apply null, JSON.parse decodeURIComponent response

  # TODO: Use IP address/port for ID?
  #
  createId: -> Math.floor Math.random() * 2000000000

ws = new WS()

# #####################################################################
# Tab utilities.

# Traverse tabs, applying `eachTab` to all tabs which match `predicate`.  When done, call `done` with a count
# of the number of matching tabs.
#
# `eachTab` must accept three arguments: a window, a tab and a callback (which it must invoke after completing
# its work).
#
tabDo = (predicate, eachTab, done=null) ->
  ws.do "chrome.windows.getAll", [{ populate:true }],
    (wins) ->
      count = 0
      intransit = 0
      for win in wins
        for tab in ( win.tabs.filter (t) -> predicate win, t )
          count += 1
          intransit += 1
          # Defer calling `eachTab` until the next tick of the event loop.  If `eachTab` is synchronous it
          # will complete immediately, and `intransit` is *guaranteed* to be 0.  So `done` gets called on
          # every iteration.  Deferring `eachTab` prevents this.
          process.nextTick ->
            eachTab win, tab, ->
              intransit -= 1
              done count if intransit == 0
      done count if done and count == 0

# A simple utility for constructing callbacks suitable for use with `ws.do`.
tabCallback = (tab, name, callback) ->
  (response) ->
    echo "done #{name}: #{tab.id} #{tab.url}"
    callback() if callback

# If there is an existing window, call `callback`, otherwise create one and call `callback`.
requireWindow = (callback) ->
  tabDo selector.fetch("window"),
    # eachTab.
    (win, tab, callback) -> callback()
    # Done.
    (count) ->
      if count then callback() else ws.do "chrome.windows.create", [{}], (response) -> callback()

# #####################################################################
# Operations:
#   - `tabOperations` these require a tab are not callable directly.
#   - `generalOperations` the exported operations.

tabOperations =

  # Focus tab.
  focus:
    ( msg, tab, callback=null) ->
      return echoErr "invalid focus: #{msg}" unless msg.length == 0
      ws.do "chrome.tabs.update", [ tab.id, { selected: true } ], tabCallback tab, "focus", callback
        
  # Reload tab.
  reload:
    ( msg, tab, callback=null) ->
      return echoErr "invalid reload: #{msg}" unless msg.length == 0
      ws.do "chrome.tabs.reload", [ tab.id, null ], tabCallback tab, "reload", callback
        
  # Close tab.
  close:
    ( msg, tab, callback=null) ->
      return echoErr "invalid close: #{msg}" unless msg.length == 0
      ws.do "chrome.tabs.remove", [ tab.id ], tabCallback tab, "close", callback

  # Goto: load the indicated URL.
  # Typically used with "with current", either explicitly or implicitly.
  # TODO: add "with new" selector?
  goto:
    ( msg, tab, callback=null) ->
      return echoErr "invalid goto: #{msg}" unless msg.length == 1 and msg[0]
      url = msg[0]
      ws.do "chrome.tabs.update", [ tab.id, { selected: true, url: url } ], tabCallback tab, "goto", callback

generalOperations =

  # Locate all tabs matching `url` and focus it.  Normally, there should be just one match or none.
  # If there is no match, then create a new tab and load `url`.
  # When done, call `callback` (if provided).
  # If the URL of a matching tab is of the form "file://...", then the file is additionally reloaded.
  load:
    (msg, callback) ->
      return echoErr "invalid load: #{msg}" unless msg and msg.length == 1
      url = msg[0]
      requireWindow ->
        tabDo selector.fetch(url),
          # `eachTab`
          (win, tab, callback) ->
            tabOperations.focus [], tab, ->
              if selector.fetch("file") win, tab then tabOperations.reload [], tab, callback else callback()
          # `done`
          (count) ->
            if count == 0
              ws.do "chrome.tabs.create", [{ url: url }],
                (response) ->
                  echo "done create: #{url}"
                  callback()
            else
              callback()

  # Apply one of `tabOperations` to all matching tabs.
  with:
    (msg, callback) ->
      return echoErr "invalid with: #{msg}" unless msg and 2 <= msg.length
      [ what ] = msg.splice 0, 1
      tabDo selector.fetch(what),
        # `eachTab`
        (win, tab, callback) ->
          cmd = msg[0]
          if cmd and tabOperations[cmd]
            tabOperations[cmd] msg[1..], tab, callback
          else
            echoErr "invalid with command: #{cmd}", true
        # `done`
        (count) ->
          callback()

  ping: (msg, callback=null) ->
    return echoErr "invalid ping: #{msg}" unless msg.length == 0
    ws.do "", [],
      (response) ->
        process.exit 1 unless response
        callback()

  # Output a list of all chrome bookmarks.  Each output line is of the form "URL title".
  bookmarks: (msg, callback, output=null, bookmark=null) ->
    return echoErr "invalid bookmarks: #{msg}" unless msg.length == 0
    if not bookmark
      # First time through (this *is not* a recursive call).
      ws.do "chrome.bookmarks.getTree", [],
        (bookmarks) =>
          bookmarks.forEach (bmark) =>
            @bookmarks msg, callback, output, bmark if bmark
          callback()
    else
      # All other times through (this *is* a recursive call).
      if bookmark.url and bookmark.title
        if output then output bookmark else echo "#{bookmark.url} #{bookmark.title}"
      if bookmark.children
        bookmark.children.forEach (bmark) =>
          @bookmarks msg, callback, output, bmark if bmark

  # A custom bookmark listing, just for smblott: "booky" support.
  booky: (msg, callback=null) ->
    regexp = new RegExp "(\\([A-Z0-9]+\\))", "g"
    @bookmarks msg, callback,
      # Output routine.
      (bmark) ->
        ( bmark.title.match(regexp) || [] ).forEach (bm) ->
          bm = bm.slice(1,-1).toLowerCase()
          echo "#{bm} #{bmark.url}"

# #####################################################################
# Execute command line arguments.

msg = conf._

# Might as well "ping" without any arguments.
msg = [ "ping" ] if msg.length == 0

# If the command is in `tabOperations`, then add "with current" to the start of it.  This gives a sensible,
# default meaning for these commands.
if msg and msg[0] and tabOperations[msg[0]] and not generalOperations[msg[0]]
  msg = "with current".split(/\s+/).concat msg

# Call the command and exit.
cmd = msg.splice(0,1)[0]
if cmd and generalOperations[cmd]
  generalOperations[cmd] msg, ( -> process.exit 0 )

else
  echoErr "invalid command: #{cmd} #{msg}"
  process.exit 1

