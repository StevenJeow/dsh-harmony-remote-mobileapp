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
import { http } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import { scanBarcode, scanCore } from '@kit.ScanKit';

@Component
export struct SetupPage {
  /** 保存成功后通知 Index 切到主界面。 */
  onDone: () => void = () => {};

  @State url: string = '';
  @State token: string = '';
  @State errorMsg: string = '';
  @State saving: boolean = false;
  /** 扫码/口头拿到的 6 位配对码 */
  @State pairCode: string = '';
  @State pairing: boolean = false;

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

  /**
   * 用 6 位配对码换取临时令牌（只走局域网）。
   * 成功后直接保存「地址 + 令牌」，不用再手抄 token。
   */
  /**
   * 扫码配对：扫电脑面板上的二维码（内容形如
   * dsh-remote://pair?b=http://192.168.1.9:3100&k=123456&n=DSH），
   * 自动填地址和配对码，然后直接换成令牌。
   */
  async doScanPair(): Promise<void> {
    if (this.pairing) {
      return;
    }
    this.errorMsg = '';
    try {
      const opt: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.ALL],
        enableMultiMode: true,
        enableAlbum: true
      };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(
        getContext(this), opt);
      const text: string = result.originalValue ?? '';
      if (text === '') {
        return;
      }
      // 解析 dsh-remote://pair?b=...&k=...&n=...
      const qIndex: number = text.indexOf('?');
      if (qIndex < 0 || text.indexOf('dsh-remote://') !== 0) {
        this.errorMsg = '这不是 DSH 的配对二维码';
        return;
      }
      const qs: string = text.substring(qIndex + 1);
      let base: string = '';
      let code: string = '';
      const parts: string[] = qs.split('&');
      for (let i = 0; i < parts.length; i++) {
        const kv: string[] = parts[i].split('=');
        if (kv.length < 2) {
          continue;
        }
        const k: string = kv[0];
        const v: string = decodeURIComponent(kv[1]);
        if (k === 'b') {
          base = v;
        } else if (k === 'k') {
          code = v;
        }
      }
      if (base === '' || !/^\d{6}$/.test(code)) {
        this.errorMsg = '二维码内容不完整（缺少地址或配对码）';
        return;
      }
      this.url = base;
      this.pairCode = code;
      await this.doPair();
    } catch (e) {
      // 用户取消扫码是正常操作，不当成错误
      const msg: string = String((e as Error).message);
      if (msg.indexOf('cancel') < 0 && msg.indexOf('Cancel') < 0) {
        this.errorMsg = '扫码失败：' + msg;
      }
    }
  }
  async doPair(): Promise<void> {
    if (this.pairing) {
      return;
    }
    const err: string = this.checkUrl();
    if (err !== '') {
      this.errorMsg = err;
      return;
    }
    if (!/^\d{6}$/.test(this.pairCode.trim())) {
      this.errorMsg = '配对码是 6 位数字';
      return;
    }
    this.pairing = true;
    this.errorMsg = '';
    const req = http.createHttp();
    try {
      const base: string = this.url.trim().replace(/\/+$/, '');
      const resp = await req.request(base + '/pair/claim', {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({ code: this.pairCode.trim() }),
        connectTimeout: 8000,
        readTimeout: 15000
      });
      const raw: string = (typeof resp.result === 'string') ? resp.result : String(resp.result);
      if (resp.responseCode === 200) {
        const data = JSON.parse(raw) as Record<string, Object>;
        const tk: string = String(data['token'] ?? '');
        if (tk === '') {
          this.errorMsg = '电脑端没返回令牌';
          return;
        }
        await RuntimeConfig.save(this.url.trim(), tk);
        promptAction.showToast({ message: '配对成功' });
        this.onDone();
      } else {
        let reason: string = '';
        try { reason = String((JSON.parse(raw) as Record<string, Object>)['reason'] ?? ''); } catch (e) {}
        if (reason === 'code-mismatch') {
          this.errorMsg = '配对码不对或已过期，去电脑上重新取一个';
        } else if (reason === 'bad-format') {
          this.errorMsg = '配对码格式不对';
        } else {
          this.errorMsg = '配对失败（HTTP ' + resp.responseCode + '）';
        }
      }
    } catch (e) {
      this.errorMsg = '连不上电脑：' + String((e as Error).message);
    } finally {
      req.destroy();
      this.pairing = false;
    }
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
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .margin({ top: 14 })

        Text('第一次使用，先填一下电脑上的服务地址')
          .fontSize(14)
          .fontColor('#8C8C8C')
          .margin({ top: 8 })

        // 表单
        Column() {
          Text('服务地址')
            .fontSize(12).fontColor('#8C8C8C')
            .width('100%')
            .margin({ top: 28 })
          TextInput({ text: this.url, placeholder: 'http://192.168.1.9:3100' })
            .width('100%').height(44).fontSize(16)
            .backgroundColor('#F5F7FA').borderRadius(12)
            .padding({ left: 14, right: 14 })
            .margin({ top: 8 })
            .onChange((value: string) => {
              this.url = value;
            })

          // ===== 配对码：扫电脑上的二维码或手输 6 位，不用手抄 token =====
          Text('配对码（推荐）')
            .fontSize(12).fontColor('#8C8C8C')
            .width('100%')
            .margin({ top: 18 })
          Row() {
            TextInput({ text: this.pairCode, placeholder: '6 位数字' })
              .layoutWeight(1)
              .height(44).fontSize(18)
              .backgroundColor('#F5F7FA').borderRadius(12)
              .padding({ left: 14, right: 14 })
              .type(InputType.Number)
              .maxLength(6)
              .onChange((value: string) => {
                this.pairCode = value;
              })
            Button(this.pairing ? '配对中…' : '配对')
              .height(44).fontSize(15)
              .borderRadius(12)
              .padding({ left: 18, right: 18 })
              .backgroundColor(this.pairing ? '#4A90D9' : '#00559E')
              .fontColor('#ffffff')
              .enabled(!this.pairing)
              .margin({ left: 10 })
              .onClick(() => {
                this.doPair();
              })
          }
          .width('100%')
          .margin({ top: 8 })
          Text('电脑上打开 DSH 面板拿到 6 位码，填进来即可，令牌会自动保存')
            .fontSize(12).fontColor('#8C8C8C')
            .width('100%')
            .margin({ top: 8 })

          Text('访问令牌')

            .fontSize(12).fontColor('#8C8C8C')
            .width('100%')
            .margin({ top: 18 })
          TextInput({ text: this.token, placeholder: '与电脑端 cordis.patch.yml 里的 token 一致' })
            .width('100%').height(44).fontSize(16)
            .backgroundColor('#F5F7FA').borderRadius(12)
            .padding({ left: 14, right: 14 })
            .margin({ top: 8 })
            .onChange((value: string) => {
              this.token = value;
            })
          Text('电脑端插件绑在 0.0.0.0 时必须填；只在本机用、绑 127.0.0.1 的可以留空')
            .fontSize(12).fontColor('#8C8C8C')
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
            .borderRadius(16)
            .backgroundColor(this.saving ? '#4A90D9' : '#00559E')
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
            .fontSize(12).fontColor('#8C8C8C')
            .textAlign(TextAlign.Center)
          Text('地址填错连不上时，在对话页的错误提示里点「改地址」可以重新填。')
            .fontSize(12).fontColor('#8C8C8C')
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
