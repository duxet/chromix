// Generated by CoffeeScript 1.4.0
(function() {
  var WSS, args, config, cxs, echo, handler, optimist, print, wss;

  config = {
    port: "7441",
    host: "localhost"
  };

  optimist = require("optimist");

  args = optimist.usage("Usage: $0 [--port=PORT] [--host=ADDRESS]").alias("h", "help")["default"]("port", config.port)["default"]("host", config.host).argv;

  if (args.help) {
    optimist.showHelp();
    process.exit(0);
  }

  print = require('sys').print;

  echo = function(msg) {
    return print("" + msg + "\n");
  };

  WSS = require("ws").Server;

  wss = new WSS({
    port: args.port,
    host: args.host
  });

  cxs = [];

  handler = function(msg) {
    var errors, i, _i, _len, _ref, _results;
    echo(msg.split(/\s+/).map(decodeURIComponent).join(" "));
    errors = [];
    cxs.forEach(function(cx, i) {
      try {
        return cx.send(msg);
      } catch (error) {
        return errors.push(i);
      }
    });
    _ref = errors.reverse();
    _results = [];
    for (_i = 0, _len = _ref.length; _i < _len; _i++) {
      i = _ref[_i];
      _results.push(cxs.splice(i, 1));
    }
    return _results;
  };

  wss.on("connection", function(ws) {
    cxs.push(ws);
    return ws.on("message", handler);
  });

}).call(this);
