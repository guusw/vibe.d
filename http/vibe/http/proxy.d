/**
	HTTP (reverse) proxy implementation

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.http.proxy;

import vibe.core.log;
import vibe.http.client;
import vibe.http.server;
import vibe.inet.message;
import vibe.stream.operations;
import vibe.internal.interfaceproxy : InterfaceProxy;

import std.conv;
import std.exception;


/*
	TODO:
		- use a client pool
		- implement a path based reverse proxy
		- implement a forward proxy
*/

/**
	Transparently forwards all requests to the proxy to a destination_host.

	You can use the hostName field in the 'settings' to combine multiple internal HTTP servers
	into one public web server with multiple virtual hosts.
*/
void listenHTTPReverseProxy(HTTPServerSettings settings, HTTPReverseProxySettings proxy_settings)
{
	// disable all advanced parsing in the server
	settings.options = HTTPServerOption.None;
	listenHTTP(settings, reverseProxyRequest(proxy_settings));
}
/// ditto
void listenHTTPReverseProxy(HTTPServerSettings settings, string destination_host, ushort destination_port)
{
	URL url;
	url.schema = "http";
	url.host = destination_host;
	url.port = destination_port;
	auto proxy_settings = new HTTPReverseProxySettings;
	proxy_settings.destination = url;
	listenHTTPReverseProxy(settings, proxy_settings);
}


/**
	Returns a HTTP request handler that forwards any request to the specified host/port.
*/
HTTPServerRequestDelegateS reverseProxyRequest(HTTPReverseProxySettings settings)
{
	static immutable string[] non_forward_headers = ["Content-Length", "Transfer-Encoding", "Content-Encoding", "Connection"];
	static InetHeaderMap non_forward_headers_map;
	if (non_forward_headers_map.length == 0)
		foreach (n; non_forward_headers)
			non_forward_headers_map[n] = "";

	auto url = settings.destination;

	void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
	@safe {
		auto rurl = url;
		rurl.localURI = req.requestURL;

		//handle connect tunnels
		if (req.method == HTTPMethod.CONNECT) {
			if (!settings.handleConnectRequests)
			{
				throw new HTTPStatusException(HTTPStatus.methodNotAllowed);
			}

			TCPConnection ccon;
			try ccon = connectTCP(url.getFilteredHost, url.port);
			catch (Exception e) {
				throw new HTTPStatusException(HTTPStatus.badGateway, "Connection to upstream server failed: "~e.msg);
			}
			auto scon = res.connectProxy();
			assert (scon);

			import vibe.core.core : runTask;
			runTask({ scon.pipe(ccon); });
			ccon.pipe(scon);
			return;
		}

		//handle protocol upgrades
		auto pUpgrade = "Upgrade" in req.headers;
		auto pConnection = "Connection" in req.headers;


		import std.algorithm : splitter, canFind;
		import vibe.utils.string : icmp2;
		bool isUpgrade = pConnection && (*pConnection).splitter(',').canFind!(a => a.icmp2("upgrade"));

		void setupClientRequest(scope HTTPClientRequest creq)
		{
			creq.method = req.method;
			creq.headers = req.headers.dup;
			creq.headers["Host"] = url.getFilteredHost;

			//handle protocol upgrades
			if (!isUpgrade) {
				creq.headers["Connection"] = "keep-alive";
			}
			if (settings.avoidCompressedRequests && "Accept-Encoding" in creq.headers)
				creq.headers.remove("Accept-Encoding");
			if (auto pfh = "X-Forwarded-Host" !in creq.headers) creq.headers["X-Forwarded-Host"] = req.headers["Host"];
			if (auto pfp = "X-Forwarded-Proto" !in creq.headers) creq.headers["X-Forwarded-Proto"] = req.tls ? "https" : "http";
			if (auto pff = "X-Forwarded-For" in req.headers) creq.headers["X-Forwarded-For"] = *pff ~ ", " ~ req.peer;
			else creq.headers["X-Forwarded-For"] = req.peer;
			req.bodyReader.pipe(creq.bodyWriter);
		}

		void handleClientResponse(scope HTTPClientResponse cres)
		{
			import vibe.utils.string;

			// copy the response to the original requester
			res.statusCode = cres.statusCode;

			//handle protocol upgrades
			if (cres.statusCode == HTTPStatus.switchingProtocols && isUpgrade) {
				res.headers = cres.headers.dup;

				auto scon = res.switchProtocol("");
				auto ccon = cres.switchProtocol("");

				import vibe.core.core : runTask;
				runTask({ ccon.pipe(scon); });

				scon.pipe(ccon);
				return;
			}

			// special case for empty response bodies
			if ("Content-Length" !in cres.headers && "Transfer-Encoding" !in cres.headers || req.method == HTTPMethod.HEAD) {
				foreach (key, ref value; cres.headers)
					if (icmp2(key, "Connection") != 0)
						res.headers[key] = value;
				res.writeVoidBody();
				return;
			}

			// enforce compatibility with HTTP/1.0 clients that do not support chunked encoding
			// (Squid and some other proxies)
			if (res.httpVersion == HTTPVersion.HTTP_1_0 && ("Transfer-Encoding" in cres.headers || "Content-Length" !in cres.headers)) {
				// copy all headers that may pass from upstream to client
				foreach (n, ref v; cres.headers)
					if (n !in non_forward_headers_map)
						res.headers[n] = v;

				if ("Transfer-Encoding" in res.headers) res.headers.remove("Transfer-Encoding");
				auto content = cres.bodyReader.readAll(1024*1024);
				res.headers["Content-Length"] = to!string(content.length);
				if (res.isHeadResponse) res.writeVoidBody();
				else res.bodyWriter.write(content);
				return;
			}

			// to perform a verbatim copy of the client response
			if ("Content-Length" in cres.headers) {
				if ("Content-Encoding" in res.headers) res.headers.remove("Content-Encoding");
				foreach (key, ref value; cres.headers)
					if (icmp2(key, "Connection") != 0)
						res.headers[key] = value;
				auto size = cres.headers["Content-Length"].to!size_t();
				if (res.isHeadResponse) res.writeVoidBody();
				else cres.readRawBody((scope InterfaceProxy!InputStream reader) { res.writeRawBody(reader, size); });
				assert(res.headerWritten);
				return;
			}

			// fall back to a generic re-encoding of the response
			// copy all headers that may pass from upstream to client
			foreach (n, ref v; cres.headers)
				if (n !in non_forward_headers_map)
					res.headers[n] = v;
			if (res.isHeadResponse) res.writeVoidBody();
			else cres.bodyReader.pipe(res.bodyWriter);
		}

		try requestHTTP(rurl, &setupClientRequest, &handleClientResponse);
		catch (Exception e) {
			throw new HTTPStatusException(HTTPStatus.badGateway, "Connection to upstream server failed: "~e.msg);
		}
	}

	return &handleRequest;
}
/// ditto
HTTPServerRequestDelegateS reverseProxyRequest(string destination_host, ushort destination_port)
{
	URL url;
	url.schema = "http";
	url.host = destination_host;
	url.port = destination_port;
	auto settings = new HTTPReverseProxySettings;
	settings.destination = url;
	return reverseProxyRequest(settings);
}

/// ditto
HTTPServerRequestDelegateS reverseProxyRequest(URL destination)
{
	auto settings = new HTTPReverseProxySettings;
	settings.destination = destination;
	return reverseProxyRequest(settings);
}

/**
	Provides advanced configuration facilities for reverse proxy servers.
*/
final class HTTPReverseProxySettings {
	/// Scheduled for deprecation - use `destination.host` instead.
	@property string destinationHost() const { return destination.host; }
	/// ditto
	@property void destinationHost(string host) { destination.host = host; }
	/// Scheduled for deprecation - use `destination.port` instead.
	@property ushort destinationPort() const { return destination.port; }
	/// ditto
	@property void destinationPort(ushort port) { destination.port = port; }

	/// The destination URL to forward requests to
	URL destination = URL("http", InetPath(""));
	/// Avoids compressed transfers between proxy and destination hosts
	bool avoidCompressedRequests;
	/// Handle CONNECT requests for creating a tunnel to the destination host
	bool handleConnectRequests;
}
