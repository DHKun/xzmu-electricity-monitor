import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/**
 * 状态栏文字颜色: 首页天空背景用白字; 设置/绑定页是浅色背景, 浅色模式下用黑字.
 * 深色模式下两种页面背景都深, 始终白字.
 */
export function setStatusBarLight(ui: UIContext, onSky: boolean): void {
  const ctx: common.UIAbilityContext = ui.getHostContext() as common.UIAbilityContext;
  const dark: boolean = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  const color: string = onSky || dark ? '#FFFFFF' : '#000000';
  window.getLastWindow(ctx).then((win: window.Window) => {
    win.setWindowSystemBarProperties({ statusBarContentColor: color, navigationBarContentColor: color })
      .catch(() => {});
  }).catch(() => {});
}
