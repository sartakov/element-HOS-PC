import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'ElementNotify';

/**
 * Wraps the HarmonyOS NotificationKit so the rest of the app can:
 *  - request notification permission once,
 *  - set the unread badge count shown on the app icon in the tray/taskbar,
 *  - publish messages to the system notification center.
 */
export class NotificationManager {
  private static instance: NotificationManager | null = null;
  private context: common.UIAbilityContext | null = null;
  private enabled: boolean = false;

  static getInstance(): NotificationManager {
    if (NotificationManager.instance === null) {
      NotificationManager.instance = new NotificationManager();
    }
    return NotificationManager.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      this.enabled = notificationManager.isNotificationEnabledSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'isNotificationEnabledSync failed: %{public}s', JSON.stringify(e));
    }
    if (!this.enabled) {
      try {
        await notificationManager.requestEnableNotification(context);
        this.enabled = true;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'requestEnableNotification failed: %{public}s', JSON.stringify(e));
      }
    }
  }

  async setBadgeNumber(count: number): Promise<void> {
    try {
      await notificationManager.setBadgeNumber(count);
      hilog.info(DOMAIN, TAG, 'Badge set to %{public}d', count);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setBadgeNumber failed: %{public}s', JSON.stringify(e));
    }
  }

  async publishMessage(title: string, text: string): Promise<void> {
    if (!this.enabled) {
      hilog.warn(DOMAIN, TAG, 'Notifications disabled; skipping publish');
      return;
    }
    const request: notificationManager.NotificationRequest = {
      id: 1,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    try {
      await notificationManager.publish(request);
      hilog.info(DOMAIN, TAG, 'Notification published: %{public}s', title);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'publish failed: %{public}s', JSON.stringify(e));
    }
  }
}
