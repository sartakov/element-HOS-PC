import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;

export default class DefaultAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    try {
      this.mainWindow = windowStage.getMainWindowSync();
      this.mainWindow.on('windowEvent', (eventType: window.WindowEventType) => {
        hilog.info(DOMAIN, 'testTag', 'Window event: %{public}d', eventType);
        if (eventType === window.WindowEventType.WINDOW_DESTROYED) {
          hilog.info(DOMAIN, 'testTag', 'Window destroyed; process stays resident in taskbar');
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to subscribe to window events: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageWillDestroy(windowStage: window.WindowStage): void {
    try {
      if (this.mainWindow !== null) {
        this.mainWindow.off('windowEvent');
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'Failed to unsubscribe window events: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onPrepareToTerminate(): boolean {
    // Cancel termination so the app stays resident; park the window in the taskbar instead.
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Close requested; canceling termination and minimizing to taskbar');
    if (this.mainWindow !== null) {
      this.mainWindow.minimize().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, 'testTag', 'Failed to minimize window: %{public}s', JSON.stringify(err));
      });
    }
    return true;
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant (reopened)');
    if (this.mainWindow !== null) {
      this.mainWindow.recover().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, 'testTag', 'Failed to recover window: %{public}s', JSON.stringify(err));
      });
    }
  }
}
