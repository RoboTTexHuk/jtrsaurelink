import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, HttpClient, HttpHeaders;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as af_core;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart'; // оставим для bg handler
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;
import 'package:untitled4/paw.dart';
import 'package:url_launcher/url_launcher.dart';

// ===================== Константы =====================
const String kStatUrl = "https://kcilc.jlinktreasure.click/stat";
const String kAxisUrl = "https://kcilc.jlinktreasure.click/";
const String kAppleId = "6752902022"; // для _postStat
const String kAppName = "jlinktreasure";
const String kBundleId = "com.hoklo.moklo.jtreslink";
const String kAfDevKey = "qsBLmy7dAXDQhowM8V3ca4";
const String kAfAppId = "6752902022";

// Значения для sendAfRaw по заданию
const String kSendBundleId = "com.hoklo.moklo.jtreslink";
const String kSendAppleId = "6752902022";
const String kSendAppVersion = "1.0.0";

// ===================== Лоадер “желтая волна” =====================
class YellowWaveLoader extends StatefulWidget {
  const YellowWaveLoader({Key? key}) : super(key: key);

  @override
  State<YellowWaveLoader> createState() => _YellowWaveLoaderState();
}

class _YellowWaveLoaderState extends State<YellowWaveLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  static const double _amplitude = 18.0;
  static const double _wavelength = 180.0;
  static const double _speed = 2.0;
  static const double _thickness = 10.0;

  @override
  void initState() {
    super.initState();
    _controller =
    AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _WavePainter(
              phase: _controller.value * 2 * 3.1415926 * _speed,
              amplitude: _amplitude,
              wavelength: _wavelength,
              color: const Color(0xFFFFD54F),
              thickness: _thickness,
              glowColor: const Color(0x33FFD54F),
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  final double phase;
  final double amplitude;
  final double wavelength;
  final double thickness;
  final Color color;
  final Color glowColor;

  _WavePainter({
    required this.phase,
    required this.amplitude,
    required this.wavelength,
    required this.color,
    required this.thickness,
    required this.glowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;

    final glowPaint = Paint()
      ..color = glowColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness * 2.2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final mainPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = thickness;

    final pathGlow = Path();
    final pathMain = Path();

    double k = (2 * 3.1415926) / wavelength;
    for (double x = 0; x <= size.width; x += 2) {
      final edgeFade = _edgeFade(x, size.width);
      final y = centerY + (amplitude * edgeFade) * _fastSin(k * x + phase);

      if (x == 0) {
        pathGlow.moveTo(x, y);
        pathMain.moveTo(x, y);
      } else {
        pathGlow.lineTo(x, y);
        pathMain.lineTo(x, y);
      }
    }

    canvas.drawPath(pathGlow, glowPaint);
    canvas.drawPath(pathMain, mainPaint);
  }

  double _edgeFade(double x, double width) {
    final distToEdge = x < width / 2 ? x : (width - x);
    final norm = (distToEdge / (width / 2)).clamp(0.0, 1.0);
    return norm * norm * (3 - 2 * norm);
  }

  double _fastSin(double x) {
    const pi = 3.1415926535897932;
    x = x % (2 * pi);
    if (x > pi) x -= 2 * pi;
    if (x < -pi) x += 2 * pi;

    const B = 4 / pi;
    const C = -4 / (pi * pi);
    final y = B * x + C * x.abs() * x;
    const P = 0.225;
    return P * (y * y.abs() - y) + y;
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase ||
          old.amplitude != amplitude ||
          old.wavelength != wavelength ||
          old.color != color ||
          old.thickness != thickness;
}

// ===================== Утилиты =====================
Future<String> _resolveFinalUrl(String startUrl, {int maxHops = 10}) async {
  final client = HttpClient();
  client.userAgent = 'Mozilla/5.0 (Flutter; dart:io HttpClient)';
  try {
    var current = Uri.parse(startUrl);
    for (int i = 0; i < maxHops; i++) {
      final req = await client.getUrl(current);
      req.followRedirects = false;
      final res = await req.close();
      if (res.isRedirect) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        if (loc == null || loc.isEmpty) break;
        final next = Uri.parse(loc);
        current = next.hasScheme ? next : current.resolveUri(next);
        continue;
      }
      return current.toString();
    }
    return current.toString();
  } catch (_) {
    return startUrl;
  } finally {
    client.close(force: true);
  }
}

Future<void> _postStat({
  required String appSid,
  required String event,
  required int timeStart,
  required int timeFinish,
  required String url,
}) async {
  try {
    final finalUrl = await _resolveFinalUrl(url);
    final payload = {
      "event": event,
      "timestart": timeStart,
      "timefinsh": timeFinish,
      "url": finalUrl,
      "appleID": kAppleId,
      "open_count": "$appSid/$timeStart",
    };
    await http.post(
      Uri.parse("$kStatUrl/$appSid"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );
  } catch (_) {}
}

class DevPack {
  String? dId;
  String? sess;
  String? plat;
  String? osv;
  String? appv;
  String? lang;
  String? tzid;
  bool push = true;

  Future<void> collect() async {
    final di = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final x = await di.androidInfo;
      dId = x.id;
      plat = "android";
      osv = x.version.release;
    } else if (Platform.isIOS) {
      final x = await di.iosInfo;
      dId = x.identifierForVendor;
      plat = "ios";
      osv = x.systemVersion;
    } else {
      plat = "unknown";
    }

    final info = await PackageInfo.fromPlatform();
    appv = info.version;
    lang = Platform.localeName.split('_').first;
    tzid = tz_zone.local.name;
    sess = "slot-${DateTime.now().millisecondsSinceEpoch}";
  }
}

bool _isNakedMail(Uri u) {
  final s = u.scheme;
  if (s.isNotEmpty) return false;
  final raw = u.toString();
  return raw.contains('@') && !raw.contains(' ');
}

Uri _toMailto(Uri u) {
  final full = u.toString();
  final parts = full.split('?');
  final email = parts.first;
  final qp = parts.length > 1 ? Uri.splitQueryString(parts[1]) : <String, String>{};
  return Uri(
    scheme: 'mailto',
    path: email,
    queryParameters: qp.isEmpty ? null : qp,
  );
}

Uri _gmailize(Uri m) {
  final qp = m.queryParameters;
  final params = <String, String>{
    'view': 'cm',
    'fs': '1',
    if (m.path.isNotEmpty) 'to': m.path,
    if ((qp['subject'] ?? '').isNotEmpty) 'su': qp['subject']!,
    if ((qp['body'] ?? '').isNotEmpty) 'body': qp['body']!,
    if ((qp['cc'] ?? '').isNotEmpty) 'cc': qp['cc']!,
    if ((qp['bcc'] ?? '').isNotEmpty) 'bcc': qp['bcc']!,
  };
  return Uri.https('mail.google.com', '/mail/', params);
}

String _digits(String s) => s.replaceAll(RegExp(r'[^0-9+]'), '');

Future<void> _openExternal(Uri u) async {
  try {
    if (await canLaunchUrl(u)) {
      await launchUrl(u, mode: LaunchMode.externalApplication);
    }
  } catch (_) {}
}

Future<void> _openWeb(Uri u) async {
  try {
    if (await canLaunchUrl(u)) {
      if (!await launchUrl(u, mode: LaunchMode.inAppBrowserView)) {
        await launchUrl(u, mode: LaunchMode.externalApplication);
      }
    }
  } catch (_) {}
}

// ===================== FCM мост (получение токена из платформы) =====================
class FcmBridge extends ChangeNotifier {
  String? token;

  FcmBridge() {
    _hook((sig) {
      token = sig;
      notifyListeners();
    });
  }

  void _hook(Function(String sig) tap) {
    const MethodChannel('com.example.fcm/token').setMethodCallHandler((call) async {
      if (call.method == 'setToken') {
        final String s = call.arguments as String;
        tap(s);
      }
    });
  }
}

final _bridge = FcmBridge();

// ===================== Главный экран =====================
class SimpleWebScreen extends StatefulWidget {
  const SimpleWebScreen({Key? key}) : super(key: key);

  @override
  State<SimpleWebScreen> createState() => _SimpleWebScreenState();
}

class _SimpleWebScreenState extends State<SimpleWebScreen> {
  InAppWebViewController? _web;
  bool _loadingOverlay = true;

  // AppsFlyer
  af_core.AppsflyerSdk? _af;
  String _afId = "";
  String _afBlob = "";

  // Для стата
  int _loadStartMs = 0;
  String _lastUrl = "";

  DevPack? _dev;
  final List<ContentBlocker> contentBlockers = [];
  @override
  void initState() {
    super.initState();

    for (final adUrlFilter in FILT) {
      contentBlockers.add(ContentBlocker(
          trigger: ContentBlockerTrigger(
            urlFilter: adUrlFilter,
          ),
          action: ContentBlockerAction(
            type: ContentBlockerActionType.BLOCK,
          )));
    }

    contentBlockers.add(ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".cookie", resourceType: [
        //   ContentBlockerTriggerResourceType.IMAGE,

        ContentBlockerTriggerResourceType.RAW
      ]),
      action: ContentBlockerAction(
          type: ContentBlockerActionType.BLOCK, selector: ".notification"),
    ));

    contentBlockers.add(ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".cookie", resourceType: [
        //   ContentBlockerTriggerResourceType.IMAGE,

        ContentBlockerTriggerResourceType.RAW
      ]),
      action: ContentBlockerAction(
          type: ContentBlockerActionType.CSS_DISPLAY_NONE,
          selector: ".privacy-info"),
    ));
    // apply the "display: none" style to some HTML elements
    contentBlockers.add(ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: ".*",
        ),
        action: ContentBlockerAction(
            type: ContentBlockerActionType.CSS_DISPLAY_NONE,
            selector: ".banner, .banners, .ads, .ad, .advert")));



    _initAppsFlyer();
    _prepareDev();
    Future.delayed(const Duration(seconds: 7), () {
      if (mounted) setState(() => _loadingOverlay = false);
    });
  }

  Future<void> _prepareDev() async {
    final dev = DevPack();
    await dev.collect();
    setState(() {
      _dev = dev;
    });
  }

  Future<void> _initAppsFlyer() async {
    try {
      final cfg = af_core.AppsFlyerOptions(
        afDevKey: kAfDevKey,
        appId: kAfAppId,
        showDebug: true,
        timeToWaitForATTUserAuthorization: 0,
      );
      _af = af_core.AppsflyerSdk(cfg);
      await _af?.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
        registerOnDeepLinkingCallback: true,
      );
      _af?.onInstallConversionData((res) {
        _afBlob = res.toString();
      });
      final id = await _af?.getAppsFlyerUID();
      _afId = id?.toString() ?? "";
      _af?.startSDK();
    } catch (_) {}
  }

  Future<void> _sendDeviceToLocalStorage() async {
    if (_web == null) return;
    final dev = _dev;
    if (dev == null) return;

    final jsonMap = jsonEncode({
      "fcm_token": _bridge.token ?? 'missing_token',
      "device_id": dev.dId ?? 'missing_id',
      "app_name": kAppName,
      "instance_id": dev.sess ?? 'missing_session',
      "platform": dev.plat ?? 'missing_system',
      "os_version": dev.osv ?? 'missing_build',
      "app_version": dev.appv ?? 'missing_app',
      "language": dev.lang ?? 'en',
      "timezone": dev.tzid ?? 'UTC',
      "push_enabled": dev.push,
    });
    print("Mao "+jsonMap.toString());
    await _web!.evaluateJavascript(
      source: "localStorage.setItem('app_data', JSON.stringify($jsonMap));",
    );
  }

  // sendAfRaw: вызывается через 6 секунд после загрузки; fcm_token всегда берём из _bridge.token
  Future<void> _sendAfRaw() async {
    if (_web == null) return;
    final dev = _dev;
    if (dev == null) return;

    final afId = _afId;
    final token = _bridge.token ?? ''; // ВСЕГДА из моста
    final content = {
      "content": {
        "af_data": _afBlob,
        "af_id": afId,
        "fb_app_name": kAppName,
        "app_name": kAppName,
        "deep": null,
        "bundle_identifier": kSendBundleId,
        "app_version": kSendAppVersion,
        "apple_id": kSendAppleId,
        "fcm_token": token,
        "device_id": dev.dId ?? "no_device",
        "instance_id": dev.sess ?? "no_instance",
        "platform": dev.plat ?? "no_type",
        "os_version": dev.osv ?? "no_os",
        "language": dev.lang ?? "en",
        "timezone": dev.tzid ?? "UTC",
        "push_enabled": dev.push,
        "useruid": afId,
      },
    };
    final jsonString = jsonEncode(content);

    print("data GET "+jsonString.toString());
    await _web!.evaluateJavascript(
      source: "try { sendRawData(${jsonEncode(jsonString)}); } catch(e) { console.log(e); }",
    );
  }

  Future<void> _postSimpleLoadedStat() async {
    if (_afId.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _postStat(
      appSid: _afId,
      event: "Loaded",
      timeStart: _loadStartMs == 0 ? now : _loadStartMs,
      timeFinish: now,
      url: _lastUrl.isEmpty ? kAxisUrl : _lastUrl,
    );
  }

  NavigationActionPolicy _handleOverride(InAppWebViewController c, Uri? uri) {
    if (uri == null) return NavigationActionPolicy.ALLOW;

    if (_isNakedMail(uri)) {
      final mailto = _toMailto(uri);
      _openWeb(_gmailize(mailto));
      return NavigationActionPolicy.CANCEL;
    }

    final sch = uri.scheme.toLowerCase();

    if (sch == 'mailto') {
      _openWeb(_gmailize(uri));
      return NavigationActionPolicy.CANCEL;
    }

    if (sch == 'tel') {
      _openExternal(Uri.parse('tel:${_digits(uri.path)}'));
      return NavigationActionPolicy.CANCEL;
    }

    final host = uri.host.toLowerCase();
    final isPlatformish = sch == 'tg' ||
        sch == 'telegram' ||
        sch == 'whatsapp' ||
        sch == 'viber' ||
        sch == 'skype' ||
        sch == 'fb-messenger' ||
        sch == 'sgnl' ||
        host.endsWith('t.me') ||
        host.endsWith('wa.me') ||
        host.endsWith('m.me') ||
        host.endsWith('signal.me');

    if (isPlatformish) {
      _openWeb(uri);
      return NavigationActionPolicy.CANCEL;
    }

    if (sch != 'http' && sch != 'https') {
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }
  void _bindBell() {
    MethodChannel('com.example.fcm/notification').setMethodCallHandler((call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> x = Map<String, dynamic>.from(
          call.arguments,
        );
        print("URI data" + x['uri'].toString());
        if (x["uri"] != null && !x["uri"].contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => NoodleWebBox (x["uri"])),
                (route) => false,
          );
        }
      }
    });
  }
  @override
  Widget build(BuildContext context) {
    _bindBell();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                disableDefaultErrorPage: false,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                contentBlockers: contentBlockers,
                allowsPictureInPictureMediaPlayback: true,
                useOnDownloadStart: true,
                javaScriptCanOpenWindowsAutomatically: true,
                useShouldOverrideUrlLoading: true,
                supportMultipleWindows: true,
                transparentBackground: true,
              ),
              initialUrlRequest: URLRequest(url: WebUri(kAxisUrl)),
              onWebViewCreated: (c) async {
                _web = c;
                c.addJavaScriptHandler(
                  handlerName: 'onServerResponse',
                  callback: (args) {
                    try {

                      print("loadr"+ args[0]['savedata'].toString());
                      if (args.isNotEmpty &&
                          args[0] is Map &&
                          args[0]['savedata'].toString() == "false") {

                        print("loadr"+ args[0]['savedata'].toString());

                      }
                    } catch (_) {}
                    return null;
                  },
                );
              },
              onLoadStart: (c, u) {
                _loadStartMs = DateTime.now().millisecondsSinceEpoch;
              },
              onLoadStop: (c, u) async {
                _lastUrl = u?.toString() ?? "";
                await _sendDeviceToLocalStorage();
                // sendAfRaw — строго через 6 секунд
                Future.delayed(const Duration(seconds: 6), () async {
                  if (!mounted) return;
                  await _sendAfRaw();
                });
                // Стат — через 2 секунды
                Future.delayed(const Duration(seconds: 2), _postSimpleLoadedStat);
              },
              onLoadError: (c, u, code, msg) async {
                debugPrint("WebView error: $code $msg for $u");
              },
              shouldOverrideUrlLoading: (c, action) async {
                return _handleOverride(c, action.request.url);
              },
              onCreateWindow: (c, req) async {
                final uri = req.request.url;
                if (uri == null) return false;
                final pol = _handleOverride(c, uri);
                if (pol == NavigationActionPolicy.ALLOW) {
                  c.loadUrl(urlRequest: URLRequest(url: uri));
                }
                return false;
              },
              onDownloadStartRequest: (c, req) async {
                await _openWeb(req.url);
              },
            ),
            if (_loadingOverlay) const YellowWaveLoader(),
          ],
        ),
      ),
    );
  }
}

// ===================== Entry point =====================
@pragma('vm:entry-point')
Future<void> _bgFcm(RemoteMessage m) async {
  debugPrint("BG FCM: ${m.messageId} data=${m.data}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_bgFcm);
  tz_data.initializeTimeZones();

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  // ВАЖНО: fcm_token берём только из платформенного канала, а не через FirebaseMessaging.getToken().
  // Здесь ничего не инициализируем для токена — ждём, когда нативный код вызовет MethodChannel setToken.

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: const ColorScheme.dark(
        primary: Colors.amber,
        surface: Colors.black,
      ),
      scaffoldBackgroundColor: Colors.black,
    ),
    home: const SimpleWebScreen(),
  ));
}

final FILT = [
  ".*.doubleclick.net/.*",
  ".*.ads.pubmatic.com/.*",
  ".*.googlesyndication.com/.*",
  ".*.google-analytics.com/.*",
  ".*.adservice.google.*/.*",
  ".*.adbrite.com/.*",
  ".*.exponential.com/.*",
  ".*.quantserve.com/.*",
  ".*.scorecardresearch.com/.*",
  ".*.zedo.com/.*",
  ".*.adsafeprotected.com/.*",
  ".*.teads.tv/.*",
  ".*.outbrain.com/.*",
];