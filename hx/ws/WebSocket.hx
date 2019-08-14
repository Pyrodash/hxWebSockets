package hx.ws;

import haxe.io.Bytes;

#if js 

import haxe.Constraints.Function;

class WebSocket { // lets use composition so we can intercept send / onmessage and convert to something haxey if its binary
    private var _ws:js.html.WebSocket = null;
    
    public function new(url:String) {
        _ws = new js.html.WebSocket(url);
    }
    
    public var onopen(get, set):Function;
    private function get_onopen():Function {
        return _ws.onopen;
    }
    private function set_onopen(value:Function):Function {
        _ws.onopen = value;
        return value;
    }
    
    public var onclose(get, set):Function;
    private function get_onclose():Function {
        return _ws.onclose;
    }
    private function set_onclose(value:Function):Function {
        _ws.onclose = function(e:js.html.CloseEvent) {
            value(e.code, e.reason);
        };
        return value;
    }
    
    public var onerror(get, set):Function;
    private function get_onerror():Function {
        return _ws.onerror;
    }
    private function set_onerror(value:Function):Function {
        _ws.onerror = value;
        return value;
    }
    
    private var _onmessage:Function = null;
    public var onmessage(get, set):Function;
    private function get_onmessage():Function {
        return _onmessage;
    }
    private function set_onmessage(value:Function):Function {
        _onmessage = value;
        _ws.onmessage = function(message) {
            if (_onmessage != null) {
                if (Std.is(message.data, js.html.ArrayBuffer)) {
                    var buffer = new Buffer();
                    buffer.writeBytes(Bytes.ofData(message.data));
                    _onmessage({
                        type: "binary",
                        data: buffer
                    });
                } else {
                    _onmessage({
                        type: "text",
                        data: message.data
                    });
                }
            }
        };
        return value;
    }
    
	public var binaryType(get, set):BinaryType;
    private function get_binaryType() {
        return _ws.binaryType;
    }
    private function set_binaryType(value:BinaryType):BinaryType {
        _ws.binaryType = value;
        return value;
    }
    
    public function close() {
        _ws.close();
    }
    
    public function send(data:Any) {
        if (Std.is(data, Buffer)) {
            var buffer = cast(data, Buffer);
            _ws.send(buffer.readAllAvailableBytes().getData());
        } else {
            _ws.send(data);
        }
    }
}

#elseif sys


#if (haxe_ver >= 4)
import sys.thread.Thread;
#elseif neko
import neko.vm.Thread;
#elseif cpp
import cpp.vm.Thread;
#end

import haxe.crypto.Base64;
import haxe.io.Error;
import hx.ws.Crypto;

class WebSocket extends WebSocketCommon {
    public var _host:String;
    public var _port:Int;
    public var _uri:String;
    public var _origin:String;

    private var _processThread:Thread;
    private var _encodedKey:String;
    
	public var binaryType:BinaryType;
    
    public function new(uri:String, ?origin:String) {
        var uriRegExp = ~/^(\w+?):\/\/([\w\.-]+)(:(\d+))?(\/.*)?$/;

        if ( ! uriRegExp.match(uri)) throw 'Uri not matching websocket uri "${uri}"';

        var proto = uriRegExp.matched(1);
        if (proto == "wss") {
            #if (java || cs)
            
            throw "Secure sockets not implemented";
            
            #else
            
            _port = 443;
            var s = new SecureSocketImpl();
            super(s);
            
            #end
        } else if (proto == "ws") {
            _port = 80;
            super();
        } else {
            throw 'Unknown protocol $proto';
        }

        _host = uriRegExp.matched(2);
        var parsedPort = Std.parseInt(uriRegExp.matched(4));
        if (parsedPort > 0 ) {
            _port = parsedPort;
        }
        _uri = uriRegExp.matched(5);
        if (_uri == null) {
            _uri = "/";
        }
        
        _origin = origin;

        _socket.setBlocking(true);

        try {
            _socket.connect(new sys.net.Host(_host), _port);
            _socket.setBlocking(false);

            /*if(_origin == null) {
                _origin = _socket.host().host.toString() + ":" + _socket.host().port;
            }*/

            _processThread = Thread.create(processThread);
            _processThread.sendMessage(this);
            
            sendHandshake();
        } catch(e:Dynamic) {
            var needClose = (!(e == 'Blocking' || (Std.is(e, Error) && (e:Error).match(Error.Blocked))));

            defer(function() {            
                if(onerror != null)
                    onerror(e);

                if(needClose)
                    handleClose();
            });
        }
    }

    private function defer(f:Void->Void) {
        haxe.Timer.delay(f, 0);
    }
    
    private function processThread() {
        var ws:WebSocket = Thread.readMessage(true);
        Log.debug("Thread started", ws.id);
        while (ws.state != State.Closed) { // TODO: should think about mutex
            ws.process();
            Sys.sleep(.01);
        }
        Log.debug("Thread ended", ws.id);
    }
    
    public function sendHandshake() {
        var httpRequest = new HttpRequest();
        httpRequest.method = "GET";
        httpRequest.uri = _uri.length > 0 ? _uri : "/";
        httpRequest.httpVersion = "HTTP/1.1";

        httpRequest.headers.set(HttpHeader.HOST, _host + ":" + _port);
        httpRequest.headers.set(HttpHeader.USER_AGENT, "hxWebSockets");
        httpRequest.headers.set(HttpHeader.SEC_WEBSOSCKET_VERSION, "13");
        httpRequest.headers.set(HttpHeader.UPGRADE, "websocket");
        httpRequest.headers.set(HttpHeader.CONNECTION, "Upgrade");
        httpRequest.headers.set(HttpHeader.PRAGMA, "no-cache");
        httpRequest.headers.set(HttpHeader.CACHE_CONTROL, "no-cache");
        if(_origin != null && _origin != '') {
            httpRequest.headers.set(HttpHeader.ORIGIN, _origin);
        }
        _encodedKey = Base64.encode(Crypto.randomBytes(16));
        httpRequest.headers.set(HttpHeader.SEC_WEBSOCKET_KEY, _encodedKey);
        
        sendHttpRequest(httpRequest);
    }

    private override function handleData() {
        switch (state) {
            case State.Handshake:
                var httpResponse = recvHttpResponse();
                if (httpResponse == null) {
                    return;
                }
                
                handshake(httpResponse);
                handleData();
            case _:
                super.handleData();
        }
                
    }
    
    private function handshake(httpResponse:HttpResponse) {
        if (httpResponse.code != 101) {
            if (onerror != null) {
                onerror(httpResponse.headers.get(HttpHeader.X_WEBSOCKET_REJECT_REASON));
            }
            close();
            return;
        }
        
        var secKey = httpResponse.headers.get(HttpHeader.SEC_WEBSOSCKET_ACCEPT);
        if (secKey != makeWSKey(_encodedKey)) {
            if (onerror != null) {
                onerror("Error during WebSocket handshake: Incorrect 'Sec-WebSocket-Accept' header value");
            }
            close();
            return;
        }

        _onopenCalled = false;
        state = State.Head;
    }
}

#end