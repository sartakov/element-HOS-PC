import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import notification from '@ohos.notification';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';

const DOMAIN = 0x0000;
const TAG = 'NotificationBridge';

interface NotifyPayload {
  title?: string;
  body?: string;
  tag?: string;
  silent?: boolean;
}

/**
 * Bridges element-web desktop notifications (the Web Notifications API, which
 * ArkWeb silently drops) to the HarmonyOS notification center and launcher badge.
 *
 * element-web runs entirely inside the WebView and shows notifications with
 * `new window.Notification(title, {...})`. A prelude.js shim replaces
 * window.Notification and forwards the call here through javaScriptProxy
 * (window.hosNative.notify(json)). This class publishes a real notification via
 * @kit.NotificationKit and tracks the app-icon badge count.
 */
export class NotificationBridge {
  private context: common.UIAbilityContext | null = null;
  private wantAgentObj: WantAgent | null = null;
  private badgeCount: number = 0;
  private nextId: number = 1;
  private enableRequested: boolean = false;
  private initPromise: Promise<void> | null = null;

  init(context: common.UIAbilityContext): void {
    if (this.context !== null) {
      return;
    }
    this.context = context;
    this.initPromise = this.doInit();
  }

  private async doInit(): Promise<void> {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const wantInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: ctx.abilityInfo.bundleName,
            abilityName: 'DefaultAbility',
          },
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG],
      };
      this.wantAgentObj = await wantAgent.getWantAgent(wantInfo);
      hilog.info(DOMAIN, TAG, 'wantAgent ready');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'wantAgent setup failed: %{public}s', JSON.stringify(e));
    }
  }

  /** Called from the WebView (JavaScriPtProxy async method). */
  notify(json: string): void {
    try {
      const payload: NotifyPayload = JSON.parse(json) as NotifyPayload;
      this.publish(payload.title ?? 'Element', payload.body ?? '', payload.tag ?? '')
        .catch((e: Error) => {
          hilog.error(DOMAIN, TAG, 'publish error: %{public}s', JSON.stringify(e));
        });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'notify parse error: %{public}s', JSON.stringify(e));
    }
  }

  /** Called from the WebView when the window regains focus (clears badge). */
  clearBadge(): void {
    this.badgeCount = 0;
    notificationManager.setBadgeNumber(0).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'setBadgeNumber(0) failed: %{public}s', JSON.stringify(e));
    });
    hilog.info(DOMAIN, TAG, 'badge cleared');
  }

  private async publish(title: string, text: string, tag: string): Promise<void> {
    if (this.initPromise !== null) {
      await this.initPromise;
    }
    const enabled: boolean = await this.ensureEnabled();
    if (!enabled) {
      hilog.warn(DOMAIN, TAG, 'notifications disabled, skipping');
      return;
    }
    this.badgeCount++;
    const request: notificationManager.NotificationRequest = {
      id: this.nextId++,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text,
        },
      },
      slotType: notification.SlotType.SOCIAL_COMMUNICATION,
      sound: '',
      badgeNumber: this.badgeCount,
    };
    if (this.wantAgentObj !== null) {
      request.wantAgent = this.wantAgentObj;
    }
    if (tag.length > 0) {
      request.groupName = tag;
    }
    hilog.info(DOMAIN, TAG, 'publishing id=%{public}d title=%{public}s badge=%{public}d',
      request.id ?? -1, title, this.badgeCount);
    try {
      await notificationManager.publish(request);
      hilog.info(DOMAIN, TAG, 'publish OK');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'publish failed: %{public}s', JSON.stringify(e));
      return;
    }
    try {
      await notificationManager.setBadgeNumber(this.badgeCount);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setBadgeNumber failed: %{public}s', JSON.stringify(e));
    }
  }

  private async ensureEnabled(): Promise<boolean> {
    try {
      if (notificationManager.isNotificationEnabledSync()) {
        return true;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'isNotificationEnabledSync failed: %{public}s', JSON.stringify(e));
    }
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null || this.enableRequested) {
      return false;
    }
    this.enableRequested = true;
    try {
      hilog.info(DOMAIN, TAG, 'requesting notification enable');
      await notificationManager.requestEnableNotification(ctx);
      return notificationManager.isNotificationEnabledSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'requestEnableNotification failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }
}