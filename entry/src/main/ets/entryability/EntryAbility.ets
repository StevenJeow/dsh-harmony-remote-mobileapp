import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ShareIntent } from '../common/ShareIntent';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      // 固定浅色模式：本应用的配色是写死的浅色方案（白底 + 深色文字 + 几个固定强调色），
      // 跟随系统深色模式会出现深底浅字的系统层与浅色卡片互相打架。
      // COLOR_MODE_NOT_SET(-1) = 跟随系统；这里用 COLOR_MODE_LIGHT(1) 锁死浅色。
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 冷启动：从分享面板拉起时，图片在这里就被带进来了，先接下
    ShareIntent.capture(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  /**
   * 热启动：应用已经在后台时又分享一张图过来。
   * 这时不会重新走 onCreate、页面也不重建，必须在这里再接一次，
   * 页面靠 ShareIntent 写的 StorageProp 计数感知。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ShareIntent.capture(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // 全屏布局（周总要求）：内容画到屏幕最上/最下，系统栏区域由页面自己留白。
      windowStage.getMainWindow().then((win: window.Window) => {
        win.setWindowLayoutFullScreen(true).catch(() => {});
        // 状态栏/手势条刷成白色，跟页面同色
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#1F2329',
          navigationBarContentColor: '#1F2329'
        }).catch(() => {});
        const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        AppStorage.setOrCreate<number>('safeTopPx', area.topRect.height);
        AppStorage.setOrCreate<number>('safeBottomPx', area.bottomRect.height);
      }).catch(() => {});
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}