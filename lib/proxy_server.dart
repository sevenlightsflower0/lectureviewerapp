import 'dart:io';

void main() async {
  const targetHost = 'lt2srv.iar.kit.edu';
  const targetPort = 443;
  const proxyPort = 8081;

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, proxyPort);
  print('🔄 Proxy running on http://localhost:$proxyPort');
  print('   Forwarding to https://$targetHost');

  final client = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;

  await for (HttpRequest req in server) {
    try {
      final targetUri = Uri(
        scheme: 'https',
        host: targetHost,
        port: targetPort,
        path: req.uri.path,
        query: req.uri.query,
      );

      print('\n📥 Request: ${req.method} ${req.uri.path}');
      print('   Query: ${req.uri.query}');

      // Create proxy request
      final proxyReq = await client.openUrl(req.method, targetUri);

      // Forward all headers except 'Host' and 'Cookie' (we'll set Cookie manually)
      req.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower != 'host' && lower != 'cookie') {
          proxyReq.headers.set(name, values.join(','));
        }
      });

      // --- Read the custom X-Forwarded-Cookie header ---
      final forwardedCookie = req.headers.value('X-Forwarded-Cookie');
      if (forwardedCookie != null && forwardedCookie.isNotEmpty) {
        proxyReq.headers.set('Cookie', forwardedCookie);
        print('🍪 Forwarded Cookie: $forwardedCookie');
      } else {
        print('⚠️ No X-Forwarded-Cookie header found, trying regular Cookie...');
        final existingCookie = req.headers.value('Cookie');
        if (existingCookie != null && existingCookie.isNotEmpty) {
          proxyReq.headers.set('Cookie', existingCookie);
          print('🍪 Using regular Cookie: $existingCookie');
        } else {
          print('❌ No cookie found in request!');
        }
      }

      // Forward body if any
      if (req.contentLength > 0) {
        final body = await req.fold<List<int>>([], (list, chunk) => list..addAll(chunk));
        proxyReq.contentLength = body.length;
        proxyReq.add(body);
      }

      // Send request
      final proxyRes = await proxyReq.close();
      print('📤 Response status: ${proxyRes.statusCode}');

      // If the target returns 401, log it clearly
      if (proxyRes.statusCode == 401) {
        print('⚠️ Target server returned 401 – cookie may be invalid.');
      }

      // Forward status and headers, but **remove** WWW-Authenticate to prevent browser login popup
      req.response.statusCode = proxyRes.statusCode;
      proxyRes.headers.forEach((name, values) {
        final lower = name.toLowerCase();
        if (lower != 'www-authenticate') { // Don't forward the Basic auth challenge
          req.response.headers.set(name, values.join(','));
        }
      });

      // Pipe body
      await proxyRes.pipe(req.response);
    } catch (e) {
      print('❌ Proxy error: $e');
      req.response
        ..statusCode = 500
        ..write('Proxy error: $e')
        ..close();
    }
  }
}