import { AbilityStage, AbilityConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'EntryAbilityStage';

export default class EntryAbilityStage extends AbilityStage {
  onCreate(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbilityStage onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbilityStage onDestroy');
  }

  async onPrepareTerminationAsync(): Promise<AbilityConstant.PrepareTermination> {
    hilog.info(DOMAIN, TAG, '%{public}s', 'App close requested; canceling termination to keep running in taskbar');
    return AbilityConstant.PrepareTermination.CANCEL;
  }
}
