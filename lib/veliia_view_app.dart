import 'dart:collection';
import 'package:veliia/app_constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

class VeliiaViewApp extends StatefulWidget {
  const VeliiaViewApp({super.key});

  @override
  State<VeliiaViewApp> createState() => _VeliiaViewAppState();
}

class _VeliiaViewAppState extends State<VeliiaViewApp> {
  InAppWebViewController? webViewController;
  final ValueNotifier<double> _progressNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<String?> _errorNotifier = ValueNotifier<String?>(null);

  static const String _hideSocialLoginScript = """
(function () {
  const css = `
    .s-login-modal-social-buttons,
    .s-user-auth-modal-social,
    .s-login-modal-social-separator,
    [class*="divider"] {
      display: none !important;
      visibility: hidden !important;
      opacity: 0 !important;
      height: 0 !important;
      margin: 0 !important;
      padding: 0 !important;
      pointer-events: none !important;
      position: absolute !important;
    }
  `;

  function inject() {
    if (document.getElementById('kill-social-final')) return;
    const style = document.createElement('style');
    style.id = 'kill-social-final';
    style.innerHTML = css;
    if (document.head) {
        document.head.appendChild(style);
    }
  }

  inject();
  setInterval(inject, 500);

  const observer = new MutationObserver(inject);
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true
  });
})();
""";

  static const String _interceptExternalLinksScript = """
(function () {
  function isExternalTarget(url) {
    if (!url) return false;
    const lower = url.toLowerCase();
    return lower.includes('wa.me/') ||
           lower.includes('api.whatsapp.com/') ||
           lower.includes('chat.whatsapp.com/') ||
           lower.startsWith('whatsapp:') ||
           lower.startsWith('tel:') ||
           lower.startsWith('mailto:') ||
           lower.startsWith('sms:') ||
           lower.startsWith('intent:');
  }

  function handleExternalClick(e) {
    let el = e.target;
    while (el && el !== document.body) {
      if (el.tagName === 'A' && el.href) {
        if (isExternalTarget(el.href)) {
          e.preventDefault();
          e.stopPropagation();
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('openExternalUrl', el.href);
          } else {
            window.location.href = el.href;
          }
          return;
        }
      }
      el = el.parentElement;
    }
  }

  document.addEventListener('click', handleExternalClick, true);

  const originalWindowOpen = window.open;
  window.open = function(url, target, features) {
    if (url && isExternalTarget(url)) {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('openExternalUrl', url);
        return null;
      }
    }
    return originalWindowOpen.apply(this, arguments);
  };
})();
""";

  @override
  void dispose() {
    _progressNotifier.dispose();
    _errorNotifier.dispose();
    super.dispose();
  }

  bool _isWhatsAppUrl(Uri uri) {
    if (uri.scheme.toLowerCase() == 'whatsapp') return true;
    final host = uri.host.toLowerCase();
    return host == 'wa.me' ||
        host.endsWith('.wa.me') ||
        host == 'api.whatsapp.com' ||
        host == 'chat.whatsapp.com' ||
        host == 'web.whatsapp.com';
  }

  bool _isCustomAppScheme(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme.isNotEmpty &&
        scheme != 'http' &&
        scheme != 'https' &&
        scheme != 'about' &&
        scheme != 'javascript' &&
        scheme != 'data' &&
        scheme != 'blob';
  }

  Future<void> _launchExternalUrl(Uri uri) async {
    try {
      final String urlString = uri.toString();

      // 1. Android Intent URLs
      if (urlString.startsWith('intent:')) {
        await _launchIntentUrl(urlString);
        return;
      }

      // 2. WhatsApp links
      if (urlString.contains('wa.me') ||
          urlString.contains('api.whatsapp.com') ||
          urlString.contains('chat.whatsapp.com') ||
          uri.scheme == 'whatsapp') {
        Uri? directWhatsappUri;
        if (uri.scheme == 'whatsapp') {
          directWhatsappUri = uri;
        } else {
          String? phone;
          String? text;

          if (uri.queryParameters.containsKey('phone')) {
            phone = uri.queryParameters['phone'];
          } else if (uri.pathSegments.isNotEmpty &&
              uri.pathSegments.first.isNotEmpty) {
            phone = uri.pathSegments.first;
          }

          text = uri.queryParameters['text'];

          if (phone != null && phone.isNotEmpty) {
            final cleanPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
            final query = <String, String>{'phone': cleanPhone};
            if (text != null && text.isNotEmpty) {
              query['text'] = text;
            }
            directWhatsappUri = Uri(
              scheme: 'whatsapp',
              host: 'send',
              queryParameters: query,
            );
          }
        }

        if (directWhatsappUri != null) {
          try {
            final launched = await launchUrl(
              directWhatsappUri,
              mode: LaunchMode.externalApplication,
            );
            if (launched) return;
          } catch (e) {
            debugPrint('Direct whatsapp scheme launch failed: \$e');
          }
        }

        // Fallback: launch web URL in external browser
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }

      // 3. Other schemes/domains
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Error launching external url (\$uri): \$e');
    }
  }

  Future<void> _launchIntentUrl(String intentString) async {
    try {
      String? fallbackUrl;
      final fallbackMatch =
          RegExp(r'S\.browser_fallback_url=([^;]+)').firstMatch(intentString);
      if (fallbackMatch != null) {
        fallbackUrl = Uri.decodeFull(fallbackMatch.group(1)!);
      }

      final schemeMatch = RegExp(r'scheme=([^;]+);').firstMatch(intentString);
      final scheme = schemeMatch?.group(1);

      final rawPath = intentString
          .replaceFirst(RegExp(r'^intent://'), '')
          .split('#Intent')
          .first;

      if (scheme != null && scheme.isNotEmpty) {
        final customUri = Uri.tryParse('\$scheme://\$rawPath');
        if (customUri != null) {
          try {
            final launched = await launchUrl(
              customUri,
              mode: LaunchMode.externalApplication,
            );
            if (launched) return;
          } catch (e) {
            debugPrint('Failed to launch custom intent scheme (\$scheme): \$e');
          }
        }
      }

      if (fallbackUrl != null) {
        final fallbackUri = Uri.tryParse(fallbackUrl);
        if (fallbackUri != null) {
          await launchUrl(fallbackUri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      debugPrint('Failed to parse intent url (\$intentString): \$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (webViewController != null && await webViewController!.canGoBack()) {
          await webViewController!.goBack();
        } else {
          if (context.mounted) {
            Navigator.of(context).maybePop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              /// شريط التحميل
              ValueListenableBuilder<double>(
                valueListenable: _progressNotifier,
                builder: (context, progress, child) {
                  if (progress < 1.0) {
                    return LinearProgressIndicator(
                      value: progress,
                      color: AppConstants.primaryColor,
                      backgroundColor: Colors.transparent,
                      minHeight: 3,
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),

              Expanded(
                child: Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(AppConstants.initialUrl),
                      ),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        domStorageEnabled: true,
                        databaseEnabled: true,
                        cacheEnabled: true,
                        hardwareAcceleration: true,
                        transparentBackground: true,
                        supportMultipleWindows: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                      ),
                      initialUserScripts: UnmodifiableListView<UserScript>([
                        UserScript(
                          source: _hideSocialLoginScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                          forMainFrameOnly: false,
                        ),
                        UserScript(
                          source: _interceptExternalLinksScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                          forMainFrameOnly: false,
                        ),
                      ]),
                      onWebViewCreated: (controller) {
                        webViewController = controller;
                        controller.addJavaScriptHandler(
                          handlerName: 'openExternalUrl',
                          callback: (args) async {
                            if (args.isNotEmpty && args[0] != null) {
                              final String urlString = args[0].toString();
                              final uri = Uri.tryParse(urlString);
                              if (uri != null) {
                                await _launchExternalUrl(uri);
                              }
                            }
                          },
                        );
                      },
                      onLoadStart: (controller, url) {
                        _progressNotifier.value = 0.0;
                        _errorNotifier.value = null;
                      },
                      onProgressChanged: (controller, progress) {
                        _progressNotifier.value = progress / 100;
                      },
                      onLoadStop: (controller, url) async {
                        _progressNotifier.value = 1.0;
                        await controller.evaluateJavascript(
                          source: _hideSocialLoginScript,
                        );
                        await controller.evaluateJavascript(
                          source: _interceptExternalLinksScript,
                        );
                      },
                      onUpdateVisitedHistory: (controller, url, isReload) async {
                        await controller.evaluateJavascript(
                          source: _hideSocialLoginScript,
                        );
                        await controller.evaluateJavascript(
                          source: _interceptExternalLinksScript,
                        );
                      },
                      // ignore: deprecated_member_use
                      onLoadError: (controller, url, code, message) {
                        _errorNotifier.value = message;
                      },
                      shouldOverrideUrlLoading:
                          (controller, navigationAction) async {
                        final uri = navigationAction.request.url;
                        if (uri == null) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        // Never intercept subframes, iframes, pixels, or trackers
                        if (navigationAction.isForMainFrame != true) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        // Allow our store domain and Salla-related domains
                        final host = uri.host.toLowerCase();
                        if (host.contains('vellia-sa.com') ||
                            host.contains('salla.sa') ||
                            host.contains('salla.com') ||
                            host.contains('salla.network') ||
                            host.contains('salla.dev')) {
                          return NavigationActionPolicy.ALLOW;
                        }

                        // Intercept custom app schemes (whatsapp://, tel:, mailto:, sms:, intent:, etc.)
                        if (_isCustomAppScheme(uri)) {
                          await _launchExternalUrl(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        // Intercept WhatsApp web links
                        if (_isWhatsAppUrl(uri)) {
                          await _launchExternalUrl(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onCreateWindow: (controller, createWindowAction) async {
                        final url = createWindowAction.request.url;
                        if (url != null &&
                            url.toString().isNotEmpty &&
                            url.toString() != 'about:blank') {
                          final uri = url;
                          if (uri.host.contains('vellia-sa.com')) {
                            await controller.loadUrl(
                              urlRequest: createWindowAction.request,
                            );
                          } else {
                            await _launchExternalUrl(uri);
                          }
                          return true;
                        }

                        // On Android, request.url is null initially.
                        // We attach a HeadlessInAppWebView with windowId to capture the URL.
                        HeadlessInAppWebView? headlessWebView;
                        headlessWebView = HeadlessInAppWebView(
                          windowId: createWindowAction.windowId,
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                          ),
                          onLoadStart: (headlessController, loadUrl) async {
                            if (loadUrl != null &&
                                loadUrl.toString().isNotEmpty &&
                                loadUrl.toString() != 'about:blank') {
                              final uri = loadUrl;
                              if (uri.host.contains('vellia-sa.com')) {
                                await controller.loadUrl(
                                  urlRequest: URLRequest(url: loadUrl),
                                );
                              } else {
                                await _launchExternalUrl(uri);
                              }
                              await headlessWebView?.dispose();
                              headlessWebView = null;
                            }
                          },
                          shouldOverrideUrlLoading:
                              (headlessController, navigationAction) async {
                            final navUrl = navigationAction.request.url;
                            if (navUrl != null &&
                                navUrl.toString().isNotEmpty &&
                                navUrl.toString() != 'about:blank') {
                              final uri = navUrl;
                              if (uri.host.contains('vellia-sa.com')) {
                                await controller.loadUrl(
                                  urlRequest: URLRequest(url: navUrl),
                                );
                              } else {
                                await _launchExternalUrl(uri);
                              }
                              await headlessWebView?.dispose();
                              headlessWebView = null;
                              return NavigationActionPolicy.CANCEL;
                            }
                            return NavigationActionPolicy.ALLOW;
                          },
                        );

                        await headlessWebView?.run();

                        // Safety timer to prevent memory leaks if window is abandoned
                        Future.delayed(const Duration(seconds: 15), () {
                          headlessWebView?.dispose();
                          headlessWebView = null;
                        });

                        return true;
                      },
                    ),

                    ValueListenableBuilder<double>(
                      valueListenable: _progressNotifier,
                      builder: (context, progress, child) {
                        bool isStarting = progress < 0.15;
                        return AnimatedOpacity(
                          opacity: isStarting ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 500),
                          child: IgnorePointer(
                            ignoring: !isStarting,
                            child: Container(color: Colors.white),
                          ),
                        );
                      },
                    ),

                    // شاشة الخطأ
                    ValueListenableBuilder<String?>(
                      valueListenable: _errorNotifier,
                      builder: (context, errorMessage, child) {
                        if (errorMessage != null) {
                          return _buildErrorWidget();
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 150,
                width: 150,
                child: Image.asset(AppConstants.splashScreenImage),
              ),
              const SizedBox(height: 16),
              const Text(
                'حدث خطأ في تحميل الصفحة',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _errorNotifier.value!,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  color: Colors.black54,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () {
                  _errorNotifier.value = null;
                  webViewController?.reload();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppConstants.primaryColor,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
                icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
                label: const Text(
                  'إعادة المحاولة',
                  style: TextStyle(fontFamily: 'Cairo', color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
