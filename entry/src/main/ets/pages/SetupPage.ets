/**
 * SetupPage.ets — 首次进入时的连接设置页
 * ---------------------------------------------------------------------------
 * 发布版不再把服务器地址写死在代码里：装完第一次打开，用户自己填
 * 「电脑的局域网地址」和「访问令牌」，存进 preferences，以后自动用回填的值。
 *
 * 为什么令牌也要填：电脑端把插件绑到 0.0.0.0（手机才连得上）时，接口强制要求
 * 每个请求带 X-DSH-Token。留空也能进，但连不上电脑、会报认证错误。
 *
 * 放置位置：entry/src/main/ets/pages/SetupPage.ets
 */
import { RuntimeConfig } from '../common/RuntimeConfig';

@Component
export struct SetupPage {
  /** 保存成功后通知 Index 切到主界面。 */
  onDone: () => void = () => {};

  @State url: string = '';
  @State token: string = '';
  @State errorMsg: string = '';
  @State saving: boolean = false;

  /** 校验用户填的地址；返回空串表示没问题。 */
  private checkUrl(): string {
    const v: string = this.url.trim();
    if (v === '') {
      return '先填一下电脑上的服务地址';
    }
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      return '地址要以 http:// 或 https:// 开头';
    }
    const rest: string = v.startsWith('http://') ? v.substring(7) : v.substring(8);
    if (rest === '' || rest.indexOf('.') < 0) {
      return '地址里要写电脑的 IP，例如 http://192.168.1.9:3100';
    }
    return '';
  }

  async doSave(): Promise<void> {
    if (this.saving) {
      return;
    }
    const err: string = this.checkUrl();
    if (err !== '') {
      this.errorMsg = err;
      return;
    }
    this.saving = true;
    this.errorMsg = '';
    try {
      await RuntimeConfig.save(this.url, this.token);
      this.onDone();
    } catch (e) {
      this.errorMsg = '保存失败：' + String((e as Error).message);
    } finally {
      this.saving = false;
    }
  }

  build() {
    Scroll() {
      Column() {
        // 品牌区
        Image($r('app.media.icon'))
          .width(72)
          .height(72)
          .objectFit(ImageFit.Contain)
          .margin({ top: 56 })

        Text('DSH 遥控器')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1e293b')
          .margin({ top: 14 })

        Text('第一次使用，先填一下电脑上的服务地址')
          .fontSize(13)
          .fontColor('#64748b')
          .margin({ top: 8 })

        // 表单
        Column() {
          Text('服务地址')
            .fontSize(12).fontColor('#94a3b8')
            .width('100%')
            .margin({ top: 28 })
          TextInput({ text: this.url, placeholder: 'http://192.168.1.9:3100' })
            .width('100%').height(44).fontSize(15)
            .backgroundColor('#f1f5f9').borderRadius(12)
            .padding({ left: 14, right: 14 })
            .margin({ top: 8 })
            .onChange((value: string) => {
              this.url = value;
            })

          Text('访问令牌')
            .fontSize(12).fontColor('#94a3b8')
            .width('100%')
            .margin({ top: 18 })
          TextInput({ text: this.token, placeholder: '与电脑端 cordis.patch.yml 里的 token 一致' })
            .width('100%').height(44).fontSize(15)
            .backgroundColor('#f1f5f9').borderRadius(12)
            .padding({ left: 14, right: 14 })
            .margin({ top: 8 })
            .onChange((value: string) => {
              this.token = value;
            })
          Text('电脑端插件绑在 0.0.0.0 时必须填；只在本机用、绑 127.0.0.1 的可以留空')
            .fontSize(11).fontColor('#94a3b8')
            .width('100%')
            .margin({ top: 8 })

          if (this.errorMsg !== '') {
            Text(this.errorMsg)
              .fontSize(12).fontColor('#dc2626')
              .width('100%')
              .margin({ top: 12 })
          }

          Button(this.saving ? '保存中…' : '保存并连接')
            .width('100%').height(46).fontSize(16)
            .borderRadius(23)
            .backgroundColor(this.saving ? '#93c5fd' : '#3b82f6')
            .fontColor('#ffffff')
            .enabled(!this.saving)
            .margin({ top: 28 })
            .onClick(() => {
              this.doSave();
            })
        }
        .width('100%')

        // 底部说明
        Column() {
          Text('手机要和电脑连同一个 Wi-Fi。')
            .fontSize(11).fontColor('#94a3b8')
            .textAlign(TextAlign.Center)
          Text('地址填错连不上时，在对话页的错误提示里点「改地址」可以重新填。')
            .fontSize(11).fontColor('#94a3b8')
            .textAlign(TextAlign.Center)
            .margin({ top: 4 })
        }
        .width('100%')
        .margin({ top: 24, bottom: 40 })
      }
      .width('100%')
      .padding({ left: 24, right: 24 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
    .scrollBar(BarState.Off)
  }
}
