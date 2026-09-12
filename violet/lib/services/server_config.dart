import 'package:violet/settings/settings.dart';

class ServerConfig {
  static const defaultUrl = 'http://192.168.0.39:3001';
  static String get webBase => Settings.prefs.getString('content_server_url') ?? defaultUrl;
  static String get dbBase => databaseBase(webBase);

  static String normalize(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'http://$text');
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const FormatException('IP 또는 http/https 서버 주소를 입력해 주세요.');
    }
    return uri.toString().replaceFirst(RegExp(r'/+$'), '');
  }

  static String databaseBase(String base) {
    final uri = Uri.parse(normalize(base));
    return (uri.port == 3001 ? uri.replace(port: 3002) : uri).toString();
  }

  static String apiBase(String base) {
    final uri = Uri.parse(normalize(base));
    return (uri.port == 3002 ? uri.replace(port: 3001) : uri).toString();
  }

  static String endpoint(String base, String path) => '${base.replaceFirst(RegExp(r'/+$'), '')}/${path.replaceFirst(RegExp(r'^/+'), '')}';

  // Keep public CDN downloads; repair LAN URLs advertised with an old IP.
  static String downloadUrl(String url, String base) {
    final uri = Uri.parse(url);
    final host = uri.host;
    final parts = host.split('.');
    final private = host == 'localhost' || host == '127.0.0.1' || host == '::1' ||
        host.startsWith('192.168.') || host.startsWith('10.') ||
        (parts.length == 4 && parts[0] == '172' &&
          (int.tryParse(parts[1]) ?? 0) >= 16 && (int.tryParse(parts[1]) ?? 0) <= 31);
    if (!private && host != Uri.parse(base).host) return url;
    return endpoint(databaseBase(base), uri.path) + (uri.hasQuery ? '?${uri.query}' : '');
  }
}
