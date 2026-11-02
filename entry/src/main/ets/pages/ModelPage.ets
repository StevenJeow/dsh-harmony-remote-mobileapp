/**
 * ModelPage.ets — 「模型」页
 * ---------------------------------------------------------------------------
 * · GET /models 拉模型目录（按供应商分组）
 * · 点某个模型 -> POST /model 切换（provider + model）
 * · 当前模型如果有推理档位（reasoning.efforts），在顶部显示一排档位胶囊，点一下即切换
 * · 切换成功后回写 @Link modelLabel，对话页顶部立刻更新
 *
 * 列表用「扁平化数组 + 单层 List」：ArkUI 里 ListItem 必须是 List 的直接子节点，
 * 嵌套 ForEach 容易踩坑，所以先把 groups 摊平成一维行数据再渲染。
 */
import { promptAction } from '@kit.ArkUI';
import {
  ModelGroup, ModelInfo, ModelSelection, ModelsData, Result, ReasoningEffort,
  fetchModels, selectModel, modelLabelOf
} from '../common/ApiClient';

/** 列表里的一行：要么是供应商分组标题，要么是一个模型。 */
interface ModelRow {
  isHeader: boolean;
  /** 分组标题 or 模型名 */
  title: string;
  /** 模型行才有 */
  provider: string;
  model: string;
  /** 是不是当前正在用的模型 */
  isCurrent: boolean;
  /** 副标题（供应商 id / 档位提示） */
  sub: string;
}

@Component
export struct ModelPage {
  @Link sessionId: string;
  @Link modelLabel: string;
  /** 当前激活的 Tab（0 对话 / 1 模型 / 2 会话）。用来做「切到本页才加载」。 */
  @Link @Watch('onTabChanged') activeTab: number;

  /** 由父组件注入：选完模型跳回对话页。 */
  onPicked: () => void = () => {};

  /** 是否已经加载过，避免来回切 Tab 反复请求。 */
  private loaded: boolean = false;

  @State rows: ModelRow[] = [];
  @State efforts: ReasoningEffort[] = [];
  @State current: ModelSelection | undefined = undefined;
  @State loading: boolean = true;
  @State switching: boolean = false;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    // Tab 容器会把三个页面都创建出来。只有当前激活的那个才真正发请求 ——
    // 否则一进 App 就同时打 5 个接口（/status×2 + /messages + /models + /sessions），
    // 其中 /sessions 要 150ms 左右，而你根本没看那一页。
    if (this.activeTab === 1) {
      this.load();
    }
  }

  /** 切到本页时才首次加载。 */
  onTabChanged(): void {
    if (this.activeTab === 1 && !this.loaded) {
      this.load();
    }
  }

  async load(): Promise<void> {
    this.loaded = true;
    this.loading = true;
    this.errorMsg = '';
    const res: Result<ModelsData> = await fetchModels(this.sessionId);
    if (!res.ok) {
      this.errorMsg = res.error;
      this.loading = false;
      return;
    }
    const d: ModelsData | undefined = res.data;
    const groups: ModelGroup[] = (d !== undefined && d.groups !== undefined) ? d.groups : [];
    const cur: ModelSelection | undefined = (d !== undefined) ? d.current : undefined;
    this.current = cur;
    if (cur !== undefined) {
      this.modelLabel = modelLabelOf(cur);
    }

    // 摊平成一行行；顺便找出当前模型支持哪些推理档位
    const flat: ModelRow[] = [];
    const curEfforts: ReasoningEffort[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g: ModelGroup = groups[i];
      const models: ModelInfo[] = (g.models !== undefined) ? g.models : [];
      flat.push({
        isHeader: true,
        title: (g.name !== undefined && g.name !== '') ? g.name : ((g.id !== undefined) ? g.id : '未命名'),
        provider: '', model: '', isCurrent: false, sub: ''
      });
      for (let j = 0; j < models.length; j++) {
        const m: ModelInfo = models[j];
        const mId: string = (m.id !== undefined) ? m.id : '';
        const isCur: boolean = (cur !== undefined && cur.provider === g.id && cur.model === mId);
        flat.push({
          isHeader: false,
          title: (m.name !== undefined && m.name !== '') ? m.name : mId,
          provider: (g.id !== undefined) ? g.id : '',
          model: mId,
          isCurrent: isCur,
          sub: (g.id !== undefined) ? g.id : ''
        });
        if (isCur && m.reasoning !== undefined && m.reasoning.efforts !== undefined) {
          for (let k = 0; k < m.reasoning.efforts.length; k++) {
            curEfforts.push(m.reasoning.efforts[k]);
          }
        }
      }
    }
    this.rows = flat;
    this.efforts = curEfforts;
    this.loading = false;
  }

  /** 切模型。effort 传空串表示用服务端默认档位。 */
  async doSelect(provider: string, model: string, effort: string): Promise<void> {
    if (this.switching) {
      return;
    }
    this.switching = true;
    const res: Result<ModelsData> = await selectModel(this.sessionId, provider, model, effort);
    this.switching = false;
    if (!res.ok) {
      promptAction.showToast({ message: res.error, duration: 3000 });
      return;
    }
    promptAction.showToast({ message: '已切换到 ' + model, duration: 1500 });
    await this.load();
    this.onPicked();
  }

  @Builder
  effortBar() {
    if (this.efforts.length > 0 && this.current !== undefined) {
      Column() {
        Row() {
          Text('推理档位').fontSize(12).fontColor('#64748b')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 6 })

        Row() {
          ForEach(this.efforts, (ef: ReasoningEffort) => {
            Text((ef.name !== undefined && ef.name !== '') ? ef.name : ((ef.id !== undefined) ? ef.id : ''))
              .fontSize(12)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8 })
              .borderRadius(14)
              .backgroundColor(this.current?.reasoningEffort === ef.id ? '#3b82f6' : '#f1f5f9')
              .fontColor(this.current?.reasoningEffort === ef.id ? '#ffffff' : '#475569')
              .onClick(() => {
                if (this.current !== undefined && ef.id !== undefined) {
                  this.doSelect(this.current.provider !== undefined ? this.current.provider : '',
                    this.current.model !== undefined ? this.current.model : '', ef.id);
                }
              })
          }, (ef: ReasoningEffort, index: number) => String(ef.id) + '-' + String(index))
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 10 })
      }
      .width('100%')
      .backgroundColor('#ffffff')
      .border({ width: { bottom: 1 }, color: '#eef2f7' })
    }
  }

  build() {
    Column() {
      // 顶部：结构跟对话页、会话页一致（主标题 16 粗 + 副信息 11 号）
      // 三个页面页头固定 72 高，切 Tab 时正文起点不会上下跳。
      Column() {
        Column() {
          Text('模型').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
          Text(this.modelLabel)
            .fontSize(11).fontColor('#3b82f6')
            .margin({ top: 6 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
      .width('100%')
      .height(72)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#ffffff')
      .border({ width: { bottom: 1 }, color: '#eef2f7' })

      this.effortBar()

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color('#3b82f6')
          Text('加载模型列表…').fontSize(13).fontColor('#94a3b8').margin({ top: 8 })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg !== '') {
        Column() {
          Text('加载失败').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1e293b')
          // 最常见的一种失败：还没有当前会话。与其甩一串 409 no-session，
          // 不如直接说人话并给一个去挑会话的按钮。
          if (this.sessionId === '') {
            Text('还没有选会话').fontSize(15).fontColor('#1e293b').margin({ top: 10 })
            Text('模型的可用列表是按会话来的，先去「会话」页挑一个')
              .fontSize(12).fontColor('#94a3b8')
              .textAlign(TextAlign.Center)
              .margin({ top: 6, left: 24, right: 24 })
            Button('去挑会话').fontSize(14).height(36).borderRadius(18)
              .backgroundColor('#3b82f6').fontColor('#ffffff')
              .padding({ left: 22, right: 22 })
              .margin({ top: 16 })
              .onClick(() => { this.activeTab = 2; })
          }
          Text(this.errorMsg).fontSize(12).fontColor('#dc2626')
            .textAlign(TextAlign.Start)
            .copyOption(CopyOptions.LocalDevice)
            .margin({ top: 10, left: 18, right: 18 })
          Button('重试').fontSize(14).height(36).borderRadius(18)
            .backgroundColor('#3b82f6').fontColor('#ffffff')
            .padding({ left: 22, right: 22 })
            .margin({ top: 16 })
            .onClick(() => { this.load(); })
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.rows, (row: ModelRow, index: number) => {
            ListItem() {
              if (row.isHeader) {
                Text(row.title)
                  .fontSize(12).fontColor('#94a3b8')
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 14, bottom: 6 })
              } else {
                Row() {
                  Column() {
                    Text(row.title).fontSize(15)
                      .fontColor(row.isCurrent ? '#3b82f6' : '#1e293b')
                      .fontWeight(row.isCurrent ? FontWeight.Bold : FontWeight.Normal)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(row.sub).fontSize(11).fontColor('#94a3b8').margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (row.isCurrent) {
                    Text('使用中').fontSize(11).fontColor('#10b981')
                  } else {
                    Text('›').fontSize(18).fontColor('#cbd5e1')
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .backgroundColor(row.isCurrent ? '#eff6ff' : '#ffffff')
                .onClick(() => {
                  if (!row.isCurrent) {
                    this.doSelect(row.provider, row.model, '');
                  }
                })
              }
            }
          }, (row: ModelRow, index: number) => row.title + '-' + row.provider + '-' + row.model + '-' + String(index))
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 1, color: '#f1f5f9' })
        .backgroundColor('#ffffff')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f8fafc')
  }
}
