import 'dart:convert';
import 'dart:io';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';

// -------------------------------- FCM background handler --------------------------------
@pragma('vm:entry-point')
Future<void> baconBgGong(RemoteMessage msg) async {
  print("Bacon message ID: ${msg.messageId}");
  print("Bacon data: ${msg.data}");
}

// -------------------------------- Main screen (renamed) --------------------------------
class NoodleWebBox extends StatefulWidget with WidgetsBindingObserver {
  final String bootUrl;
  NoodleWebBox(this.bootUrl, {super.key});

  @override
  State<NoodleWebBox> createState() => _NoodleWebBoxState(bootUrl);
}

class _NoodleWebBoxState extends State<NoodleWebBox> with WidgetsBindingObserver {
  _NoodleWebBoxState(this._baseUrl);

  // WebView
  late InAppWebViewController _web;

  // FCM token and device info
  String? _fcmToken;
  String? _deviceId;
  String? _instanceId;
  String? _platformType;
  String? _osVersion;
  String? _appVersion;
  bool _pushEnabled = true;
  final List<ContentBlocker> contentBlockers = [];
  // UI
  bool _showLoader = false;
  var _dummyGate = true;

  // Navigation/state
  String _baseUrl;
  DateTime? _pausedAt;

  // External links
  final Set<String> _extHosts = {
    't.me', 'telegram.me', 'telegram.dog',
    'wa.me', 'api.whatsapp.com', 'chat.whatsapp.com',
    'bnl.com', 'www.bnl.com',
  };
  final Set<String> _extSchemes = {'tg', 'telegram', 'whatsapp', 'bnl'};

  // AppsFlyer
  AppsflyerSdk? _af;
  String _afConversionDump = "";
  String _afUid = "";

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


    WidgetsBinding.instance.addObserver(this);

    FirebaseMessaging.onBackgroundMessage(baconBgGong);

    _initAppsFlyer();
    _initFcm();
    _collectDeviceInfo();
    _wireFcmStreams();
    _bindNotificationTapChannel();

    // Reserved delayed hooks if needed
    Future.delayed(const Duration(seconds: 2), () {});
    Future.delayed(const Duration(seconds: 6), () {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // -------------------------------- Lifecycle --------------------------------
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    }
    if (s == AppLifecycleState.resumed) {
      if (Platform.isIOS && _pausedAt != null) {
        final now = DateTime.now();
        final span = now.difference(_pausedAt!);
        if (span > const Duration(minutes: 25)) {
          _hardRestart();
        }
      }
      _pausedAt = null;
    }
  }

  void _hardRestart() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => NoodleWebBox(_baseUrl)),
            (route) => false,
      );
    });
  }

  // -------------------------------- Init blocks --------------------------------
  void _wireFcmStreams() {
    FirebaseMessaging.onMessage.listen((RemoteMessage m) {
      if (m.data['uri'] != null) {
        _jumpTo(m.data['uri'].toString());
      } else {
        _backToBase();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage m) {
      if (m.data['uri'] != null) {
        _jumpTo(m.data['uri'].toString());
      } else {
        _backToBase();
      }
    });
  }

  Future<void> _initFcm() async {
    final fm = FirebaseMessaging.instance;
    await fm.requestPermission(alert: true, badge: true, sound: true);
    // Standard way to get token; if you use MethodChannel token, replace here.
    _fcmToken = await fm.getToken();
  }

  void _initAppsFlyer() {
    final opts = AppsFlyerOptions(
      afDevKey: "qsBLmy7dAXDQhowM8V3ca4",
      appId: "6745261464",
      showDebug: true,
    );
    _af = AppsflyerSdk(opts);
    _af?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );
    _af?.startSDK(
      onSuccess: () => print("AppsFlyer started"),
      onError: (int c, String m) => print("AppsFlyer error: $c $m"),
    );
    _af?.onInstallConversionData((data) {
      setState(() {
        _afConversionDump = data.toString();
      });
    });
    _af?.getAppsFlyerUID().then((v) {
      setState(() {
        _afUid = v.toString();
      });
    }).catchError((_) {});
  }

  Future<void> _collectDeviceInfo() async {
    try {
      final di = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await di.androidInfo;
        _deviceId = a.id;
        _platformType = "android";
        _instanceId = a.version.release; // kept from original mismatch
      } else if (Platform.isIOS) {
        final i = await di.iosInfo;
        _deviceId = i.identifierForVendor;
        _platformType = "ios";
        _instanceId = i.systemVersion; // kept from original mismatch
      }
      final pkg = await PackageInfo.fromPlatform();
      _osVersion = Platform.localeName.split('_')[0]; // kept as in original
      _appVersion = tz.local.name; // kept as in original
    } catch (e) {
      debugPrint("Device info error: $e");
    }
  }

  void _bindNotificationTapChannel() {
    MethodChannel('com.example.fcm/notification').setMethodCallHandler((call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> m = Map<String, dynamic>.from(call.arguments);
        final uriStr = m['uri']?.toString() ?? "";
        if (uriStr.isNotEmpty && !uriStr.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => SimpleWebScreen()),
                (route) => false,
          );
        }
      }
    });
  }

  // -------------------------------- Navigation --------------------------------
  void _jumpTo(String url) async {
    if (_web != null) {
      await _web.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  void _backToBase() async {
    Future.delayed(const Duration(seconds: 3), () {
      if (_web != null) {
        _web.loadUrl(urlRequest: URLRequest(url: WebUri(_baseUrl)));
      }
    });
  }

  // -------------------------------- UI --------------------------------
  @override
  Widget build(BuildContext context) {
    _bindNotificationTapChannel(); // ensure it's alive

    final isDark = MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        body: Stack(
          children: [
            InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                disableDefaultErrorPage: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                contentBlockers: contentBlockers,
                allowsPictureInPictureMediaPlayback: true,
                useOnDownloadStart: true,
                javaScriptCanOpenWindowsAutomatically: true,
                useShouldOverrideUrlLoading: true,
                supportMultipleWindows: true,
              ),
              initialUrlRequest: URLRequest(url: WebUri(_baseUrl)),
              onWebViewCreated: (c) {
                _web = c;
                _web.addJavaScriptHandler(
                  handlerName: 'onServerResponse',
                  callback: (args) {
                    print("JS bridge args: $args");
                    try {
                      return args.reduce((a, b) => "$a$b");
                    } catch (_) {
                      return args.toString();
                    }
                  },
                );
              },
              onLoadStart: (c, u) async {
                if (u != null) {
                  if (_looksLikePlainEmail(u)) {
                    try {
                      await c.stopLoading();
                    } catch (_) {}
                    final m = _toMailto(u);
                    await _openEmailWeb(m);
                    return;
                  }
                  final sch = u.scheme.toLowerCase();
                  if (sch != 'http' && sch != 'https') {
                    try {
                      await c.stopLoading();
                    } catch (_) {}
                  }
                }
              },
              onLoadStop: (c, u) async {
                await c.evaluateJavascript(source: "console.log('Hello from funny build!');");
              },
              shouldOverrideUrlLoading: (c, action) async {
                final u = action.request.url;
                if (u == null) return NavigationActionPolicy.ALLOW;

                if (_looksLikePlainEmail(u)) {
                  final m = _toMailto(u);
                  await _openEmailWeb(m);
                  return NavigationActionPolicy.CANCEL;
                }

                final sch = u.scheme.toLowerCase();
                if (sch == 'mailto') {
                  await _openEmailWeb(u);
                  return NavigationActionPolicy.CANCEL;
                }

                if (_isExternalWorld(u)) {
                  await _openInBrowser(_toExternalHttp(u));
                  return NavigationActionPolicy.CANCEL;
                }

                if (sch != 'http' && sch != 'https') {
                  return NavigationActionPolicy.CANCEL;
                }

                return NavigationActionPolicy.ALLOW;
              },
              onCreateWindow: (c, req) async {
                final u = req.request.url;
                if (u == null) return false;

                if (_looksLikePlainEmail(u)) {
                  final m = _toMailto(u);
                  await _openEmailWeb(m);
                  return false;
                }

                final sch = u.scheme.toLowerCase();
                if (sch == 'mailto') {
                  await _openEmailWeb(u);
                  return false;
                }

                if (_isExternalWorld(u)) {
                  await _openInBrowser(_toExternalHttp(u));
                  return false;
                }

                if (sch == 'http' || sch == 'https') {
                  c.loadUrl(urlRequest: URLRequest(url: u));
                }
                return false;
              },
            ),
            if (_showLoader)
              Visibility(
                visible: !_showLoader,
                child: SizedBox.expand(
                  child: Container(
                    color: Colors.black,
                    child: Center(
                      child: CircularProgressIndicator(
                        backgroundColor: Colors.grey.shade800,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.yellow),
                        strokeWidth: 8,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // -------------------------------- Helpers: email/external --------------------------------
  bool _looksLikePlainEmail(Uri u) {
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

  bool _isExternalWorld(Uri u) {
    final sch = u.scheme.toLowerCase();
    if (_extSchemes.contains(sch)) return true;

    if (sch == 'http' || sch == 'https') {
      final h = u.host.toLowerCase();
      if (_extHosts.contains(h)) return true;
    }
    return false;
  }

  Uri _toExternalHttp(Uri u) {
    final sch = u.scheme.toLowerCase();

    if (sch == 'tg' || sch == 'telegram') {
      final qp = u.queryParameters;
      final domain = qp['domain'];
      if (domain != null && domain.isNotEmpty) {
        return Uri.https('t.me', '/$domain', {
          if (qp['start'] != null) 'start': qp['start']!,
        });
      }
      final path = u.path.isNotEmpty ? u.path : '';
      return Uri.https('t.me', '/$path', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    if (sch == 'whatsapp') {
      final qp = u.queryParameters;
      final phone = qp['phone'];
      final text = qp['text'];
      if (phone != null && phone.isNotEmpty) {
        return Uri.https('wa.me', '/${_digitsOnly(phone)}', {
          if (text != null && text.isNotEmpty) 'text': text,
        });
      }
      return Uri.https('wa.me', '/', {if (text != null && text.isNotEmpty) 'text': text});
    }

    if (sch == 'bnl') {
      final newPath = u.path.isNotEmpty ? u.path : '';
      return Uri.https('bnl.com', '/$newPath', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    return u;
  }

  Future<bool> _openEmailWeb(Uri mailto) async {
    final g = _mailtoToGmail(mailto);
    return await _openInBrowser(g);
  }

  Uri _mailtoToGmail(Uri m) {
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

  Future<bool> _openInBrowser(Uri u) async {
    try {
      if (await launchUrl(u, mode: LaunchMode.inAppBrowserView)) return true;
      return await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Browser open error: $e; url=$u');
      try {
        return await launchUrl(u, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
  }

  String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9+]'), '');
}

// -------------------------------- Entry point --------------------------------

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