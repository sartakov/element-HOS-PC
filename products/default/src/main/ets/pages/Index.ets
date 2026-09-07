import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { LocalHttpServer } from '../local/LocalHttpServer';
import { RawfileExtractor } from '../local/RawfileExtractor';
import { NotificationBridge } from '../local/NotificationBridge';

const DOMAIN = 0x0000;
const TAG = 'ElementIndex';

/**
 * Element for HarmonyOS
 *
 * Hosts the built element-web client inside an ArkWeb (Web) component.
 * The element-web static bundle (index.html + bundles + config.json) is
 * packaged under resources/rawfile/element, extracted into the app sandbox,
 * and served from a local HTTP server (http://127.0.0.1:<port>) so that
 * fetch(), ServiceWorker, config.json loading and IndexedDB all work.
 */
@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private server: LocalHttpServer | null = null;
  private notifications: NotificationBridge = new NotificationBridge();
  @State isLoading: boolean = true;
  @State loadError: string = '';
  @State baseUrl: string = '';

  build() {
    Stack() {
      if (this.loadError.length === 0) {
        if (this.baseUrl.length > 0) {
          Web({ src: this.baseUrl, controller: this.controller })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .databaseAccess(true)
            .fileAccess(true)
            .mixedMode(MixedMode.All)
            .cacheMode(CacheMode.None)
            .javaScriptProxy({
              object: this.notifications,
              name: 'hosNative',
              methodList: [],
              asyncMethodList: ['notify', 'clearBadge'],
              controller: this.controller
            })
            .userAgent('Mozilla/5.0 (Linux; Android 14; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36')
            .width('100%')
            .height('100%')
            .onPageBegin((event) => {
              hilog.info(DOMAIN, TAG, 'Page begin: %{public}s', event.url);
            })
            .onPageEnd((event) => {
              hilog.info(DOMAIN, TAG, 'Element loaded: %{public}s', event.url);
              this.isLoading = false;
            })
            .onErrorReceive((event) => {
              let url: string = event.request.getRequestUrl();
              hilog.error(DOMAIN, TAG, 'Load error code=%{public}d url=%{public}s mainFrame=%{public}s',
                event.error.getErrorCode(), url, event.request.isMainFrame());
              if (!event.request.isMainFrame()) {
                hilog.info(DOMAIN, TAG, 'Ignoring non-critical sub-resource error (main page loads separately)');
                return;
              }
              this.loadError = `Unable to load Element`;
              let info: string = '';
              try {
                info = event.error.getErrorInfo();
              } catch (e) {
                info = 'unknown';
              }
              this.loadError += ` (${info})`;
              this.isLoading = false;
            })
            .onConsole((event) => {
              hilog.info(DOMAIN, TAG, 'Page console [%{public}s]: %{public}s',
                event.message.getSourceId(), event.message.getMessage());
              return false;
            })
            .onPermissionRequest((event) => {
              hilog.info(DOMAIN, TAG, 'Permission requested from %{public}s: %{public}s',
                event.request.getOrigin(), event.request.getAccessibleResource().join(','));
              return false;
            })
        }
      } else {
        Column() {
          Text('Element')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 16 })
          Text(this.loadError)
            .fontSize(16)
            .textAlign(TextAlign.Center)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .height('100%')
        .padding(24)
      }

      if (this.isLoading && this.loadError.length === 0) {
        LoadingProgress()
          .width(48)
          .height(48)
          .color($r('sys.color.ohos_id_color_primary'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }

  onBackPress(): boolean {
    if (this.controller.accessBackward()) {
      return true;
    }
    return false;
  }

  aboutToAppear(): void {
    try {
      webview.WebviewController.setWebDebuggingAccess(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Unable to enable web debugging: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, TAG, 'Element WebView about to appear');
    this.startElement();
  }

  aboutToDisappear(): void {
    if (this.server !== null) {
      this.server.stop().catch(() => {
        // ignore
      });
      this.server = null;
    }
  }

  private async startElement(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.notifications.init(ctx);
      const destRoot: string = ctx.filesDir + '/element';
      const current: boolean = await RawfileExtractor.isCurrent(ctx, destRoot);
      if (!current) {
        await RawfileExtractor.copyToSandbox(ctx, 'element', destRoot);
      }
      const server: LocalHttpServer = new LocalHttpServer(destRoot);
      this.server = server;
      const baseUrl: string = await server.start();
      this.baseUrl = baseUrl;
      hilog.info(DOMAIN, TAG, 'Element server started at %{public}s', baseUrl);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to start Element server: %{public}s', JSON.stringify(e));
      this.loadError = 'Unable to start local server';
      this.isLoading = false;
    }
  }
}
