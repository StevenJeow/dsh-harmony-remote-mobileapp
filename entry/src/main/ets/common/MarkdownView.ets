/**
 * MarkdownView.ets — 轻量 Markdown 渲染器（纯原生 ArkUI，无第三方依赖）
 * ---------------------------------------------------------------------------
 * 为什么不用内置 Markdown 组件：**这个 SDK 里没有**。
 * 全量核对过 D:\DevEco Studio\sdk\default\{openharmony,hms}：
 *   · 没有 ets/component/markdown.d.ts
 *   · 没有 declare const Markdown / MarkdownInterface / markdownStyle
 *   · @kit.ArkUI 的导出列表里也没有 Markdown
 * （全 SDK 唯一的 "markdown" 命中是 @ohos.data.uniformTypeDescriptor 里的 MIME 字符串。）
 * 写 Markdown({...}) 会直接编译失败。RichText 虽然存在，但它内部是 web 式渲染，
 * 放进消息列表里每个气泡一个实例会严重拖累滚动。
 *
 * 所以这里用 ArkUI 原生能力自己渲染：
 *   · 块级：Column 逐块渲染（标题 / 代码块 / 表格 / 列表 / 引用 / 分隔线 / 段落）
 *   · 行内：一个 Text 里放多个 Span，各自带 fontWeight / fontStyle / fontColor / decoration
 *   · 代码块和表格放进横向 Scroll —— 这样再宽的代码和再多列的表也不会撑破屏幕
 */
/* ==========================================================================
 * 数据结构
 * ========================================================================== */

/** 一段行内文本及其样式。 */
export interface MdInline {
  text: string;
  bold: boolean;
  italic: boolean;
  code: boolean;
  link: boolean;
}

/** 一个块级元素。 */
export interface MdBlock {
  /** 'h' 标题 | 'code' 围栏代码块 | 'table' 表格 | 'list' 列表 | 'quote' 引用 | 'rule' 分隔线 | 'p' 段落 */
  kind: string;
  /** 标题为 1..6；列表 0=无序、1=有序；其余为 0 */
  level: number;
  /** 需要行内渲染的块用这个 */
  inline: MdInline[];
  /** 代码块的行 / 表格的原始行 */
  raw: string[];
}

/* ==========================================================================
 * 解析（纯函数，跟 UI 无关）
 * ========================================================================== */

function pushSpan(out: MdInline[], text: string, bold: boolean, italic: boolean,
  code: boolean, link: boolean): void {
  if (text === '') {
    return;
  }
  out.push({ text: text, bold: bold, italic: italic, code: code, link: link });
}

/**
 * 行内解析：`code`、**粗体**、*斜体*、[文字](链接)。
 *
 * 采用**配对查找**而不是「遇到标记就翻转状态」：
 * 开关式解析一旦碰到一个落单的 `**`（真实消息里很常见，比如正文里写了个星号），
 * 后面所有 `**` 的语义就全部反转 —— 粗体丢失、`**` 原样漏到界面上。
 * 配对查找则把找不到配对的标记当普通文字输出，单点异常不会污染整条消息。
 */
export function parseInline(src: string): MdInline[] {
  const out: MdInline[] = [];
  let buf: string = '';
  let i: number = 0;

  const flush = (): void => {
    pushSpan(out, buf, false, false, false, false);
    buf = '';
  };

  while (i < src.length) {
    const ch: string = src.charAt(i);
    const two: string = src.substring(i, i + 2);

    // 行内代码 —— 优先级最高，里面的 * _ 不该被当成强调
    if (ch === '`') {
      const end: number = src.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        pushSpan(out, src.substring(i + 1, end), false, false, true, false);
        i = end + 1;
        continue;
      }
    }

    // 粗体：** 后面必须紧跟非空白才有资格当"开标记"；
    // 配对的"闭标记"前面也必须是非空白。
    // 只靠 indexOf 找下一个 ** 是不够的 —— 落单的 ** 会把后面真正的开标记
    // 当成自己的闭标记，从而吞掉中间一大段文字。
    if (two === '**' || two === '__') {
      const nextCh: string = (i + 2 < src.length) ? src.charAt(i + 2) : '';
      if (nextCh !== '' && nextCh !== ' ') {
        let search: number = i + 2;
        let end: number = -1;
        while (search < src.length) {
          const found: number = src.indexOf(two, search);
          if (found < 0) {
            break;
          }
          if (found > i + 2 && src.charAt(found - 1) !== ' ') {
            end = found;
            break;
          }
          search = found + 2;
        }
        if (end > i + 2) {
          flush();
          pushSpan(out, src.substring(i + 2, end), true, false, false, false);
          i = end + 2;
          continue;
        }
      }
      // 不满足开标记条件，或找不到能收尾的配对 —— 当普通文字，绝不吞后面的内容
      buf += two;
      i += 2;
      continue;
    }

    // 链接：[文字](url)
    if (ch === '[') {
      const close: number = src.indexOf(']', i + 1);
      const open: number = src.indexOf('(', close + 1);
      const endP: number = src.indexOf(')', open + 1);
      if (close > i && open === close + 1 && endP > open) {
        flush();
        pushSpan(out, src.substring(i + 1, close), false, false, false, true);
        i = endP + 1;
        continue;
      }
    }

    // 斜体：单个 * 或 _，同样要求后面紧跟非空白、且能找到前面非空白的配对
    if (ch === '*' || ch === '_') {
      const nextCh: string = (i + 1 < src.length) ? src.charAt(i + 1) : '';
      if (nextCh !== '' && nextCh !== ' ') {
        let search: number = i + 1;
        let end: number = -1;
        while (search < src.length) {
          const found: number = src.indexOf(ch, search);
          if (found < 0) {
            break;
          }
          if (found > i + 1 && src.charAt(found - 1) !== ' ') {
            end = found;
            break;
          }
          search = found + 1;
        }
        if (end > i + 1) {
          flush();
          pushSpan(out, src.substring(i + 1, end), false, true, false, false);
          i = end + 1;
          continue;
        }
      }
    }

    // 删除线标记：直接跳过波浪线，文字保留
    if (two === '~~') {
      i += 2;
      continue;
    }

    buf += ch;
    i += 1;
  }
  flush();
  return out;
}

/** `# 标题` 层级；不是标题返回 0。 */
function headingLevel(line: string): number {
  let n: number = 0;
  while (n < line.length && line.charAt(n) === '#') {
    n += 1;
  }
  if (n === 0 || n > 6) {
    return 0;
  }
  // `#` 后面必须是空格或行尾，否则 `#标签` 会被误判成标题
  if (n < line.length && line.charAt(n) !== ' ') {
    return 0;
  }
  return n;
}

/** `|---|---|` 这种表格分隔行。 */
function isTableSeparator(line: string): boolean {
  const t: string = line.trim();
  if (t.indexOf('|') < 0 || t.indexOf('-') < 0) {
    return false;
  }
  for (let i = 0; i < t.length; i++) {
    const c: string = t.charAt(i);
    if (c !== '|' && c !== '-' && c !== ':' && c !== ' ') {
      return false;
    }
  }
  return true;
}

/** 把 `| a | b |` 切成 ['a','b']。 */
export function splitRow(line: string): string[] {
  let t: string = line.trim();
  if (t.startsWith('|')) {
    t = t.substring(1);
  }
  if (t.endsWith('|')) {
    t = t.substring(0, t.length - 1);
  }
  const parts: string[] = t.split('|');
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    out.push(parts[i].trim());
  }
  return out;
}

/** 无序列表项 `- x` / `* x` / `+ x`。 */
function bulletBody(line: string): string {
  const t: string = line.trim();
  if (t.length < 2) {
    return '';
  }
  const c: string = t.charAt(0);
  if ((c === '-' || c === '*' || c === '+') && t.charAt(1) === ' ') {
    return t.substring(2);
  }
  return '';
}

/** 有序列表项 `1. x` 的正文；不是则返回空串。 */
function orderedBody(line: string): string {
  const t: string = line.trim();
  let i: number = 0;
  while (i < t.length && t.charAt(i) >= '0' && t.charAt(i) <= '9') {
    i += 1;
  }
  if (i === 0 || i + 1 >= t.length) {
    return '';
  }
  if (t.charAt(i) === '.' && t.charAt(i + 1) === ' ') {
    return t.substring(i + 2);
  }
  return '';
}

/** 把整段 Markdown 切成块。 */
export function parseMarkdown(src: string): MdBlock[] {
  const lines: string[] = src.split('\n');
  const blocks: MdBlock[] = [];
  let i: number = 0;

  while (i < lines.length) {
    const line: string = lines[i];
    const trimmed: string = line.trim();

    // 空行
    if (trimmed === '') {
      i += 1;
      continue;
    }

    // ``` 围栏代码块
    if (trimmed.startsWith('```')) {
      const code: string[] = [];
      i += 1;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.push(lines[i]);
        i += 1;
      }
      i += 1; // 跳过收尾围栏
      blocks.push({ kind: 'code', level: 0, inline: [], raw: code });
      continue;
    }

    // 表格：本行有 | 且下一行是分隔行
    if (trimmed.indexOf('|') >= 0 && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const rows: string[] = [];
      rows.push(trimmed);
      i += 2; // 表头 + 分隔行
      while (i < lines.length && lines[i].trim().indexOf('|') >= 0 && lines[i].trim() !== '') {
        rows.push(lines[i].trim());
        i += 1;
      }
      blocks.push({ kind: 'table', level: 0, inline: [], raw: rows });
      continue;
    }

    // 标题
    const h: number = headingLevel(trimmed);
    if (h > 0) {
      blocks.push({ kind: 'h', level: h, inline: parseInline(trimmed.substring(h).trim()), raw: [] });
      i += 1;
      continue;
    }

    // 分隔线
    if (trimmed === '---' || trimmed === '***' || trimmed === '___') {
      blocks.push({ kind: 'rule', level: 0, inline: [], raw: [] });
      i += 1;
      continue;
    }

    // 引用（连续多行合并成一块）
    if (trimmed.startsWith('> ')) {
      let quoted: string = '';
      while (i < lines.length && lines[i].trim().startsWith('> ')) {
        quoted += (quoted === '' ? '' : ' ') + lines[i].trim().substring(2);
        i += 1;
      }
      blocks.push({ kind: 'quote', level: 0, inline: parseInline(quoted), raw: [] });
      continue;
    }

    // 列表（连续同类项合并成一块，逐项一条 inline）
    const firstBullet: string = bulletBody(trimmed);
    const firstOrdered: string = orderedBody(trimmed);
    if (firstBullet !== '' || firstOrdered !== '') {
      const ordered: boolean = (firstBullet === '');
      const items: string[] = [];
      while (i < lines.length) {
        const t: string = lines[i].trim();
        const b: string = bulletBody(t);
        const o: string = orderedBody(t);
        if (ordered && o !== '') {
          items.push(o);
        } else if (!ordered && b !== '') {
          items.push(b);
        } else {
          break;
        }
        i += 1;
      }
      const flat: MdInline[] = [];
      for (let k = 0; k < items.length; k++) {
        if (k > 0) {
          flat.push({ text: '\n', bold: false, italic: false, code: false, link: false });
        }
        const one: MdInline[] = parseInline(items[k]);
        for (let m = 0; m < one.length; m++) {
          flat.push(one[m]);
        }
      }
      blocks.push({ kind: 'list', level: ordered ? 1 : 0, inline: flat, raw: items });
      continue;
    }

    // 段落：一直吃到空行或下一个块级起始
    const para: string[] = [];
    while (i < lines.length) {
      const t: string = lines[i].trim();
      if (t === '' || t.startsWith('```') || t.startsWith('> ') || headingLevel(t) > 0
        || bulletBody(t) !== '' || orderedBody(t) !== '') {
        break;
      }
      para.push(t);
      i += 1;
    }
    if (para.length > 0) {
      let joined: string = '';
      for (let k = 0; k < para.length; k++) {
        joined += (k === 0 ? '' : '\n') + para[k];
      }
      blocks.push({ kind: 'p', level: 0, inline: parseInline(joined), raw: [] });
    }
  }
  return blocks;
}

/* ==========================================================================
 * 渲染
 * ========================================================================== */

/** 代码块的配色（固定深色，浅色模式下也清晰）。 */
const CODE_BG: string = '#1e293b';
const CODE_FG: string = '#e2e8f0';
const LINK_FG: string = '#3b82f6';

@Component
export struct MarkdownView {
  /** Markdown 原文。 */
  @Prop @Watch('onTextChanged') text: string = '';
  /** true = 用户气泡（蓝底白字），false = 助手气泡（灰底深字）。 */
  @Prop @Watch('onTextChanged') isUser: boolean = false;

  @State blocks: MdBlock[] = [];

  aboutToAppear(): void {
    this.blocks = parseMarkdown(this.text);
  }

  onTextChanged(): void {
    this.blocks = parseMarkdown(this.text);
  }

  /** 行内文本的颜色：用户气泡里是白字，助手气泡里是深字；代码/链接各有自己的色。 */
  inlineColor(span: MdInline): string {
    if (span.link) {
      return this.isUser ? '#bfdbfe' : LINK_FG;
    }
    if (span.code) {
      return this.isUser ? '#fde68a' : '#b45309';
    }
    return this.isUser ? '#ffffff' : '#1e293b';
  }

  /** 标题字号随层级递减。 */
  headingSize(level: number): number {
    if (level <= 1) {
      return 19;
    }
    if (level === 2) {
      return 17;
    }
    if (level === 3) {
      return 16;
    }
    return 15;
  }

  build() {
    Column() {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        if (block.kind === 'code') {
          // 代码块：横向可滚，永远不撑破屏幕
          Scroll() {
            Column() {
              ForEach(block.raw, (codeLine: string, li: number) => {
                Text(codeLine === '' ? ' ' : codeLine)
                  .fontSize(12)
                  .fontFamily('monospace')
                  .fontColor(CODE_FG)
                  .textAlign(TextAlign.Start)
              }, (codeLine: string, li: number) => String(li) + '-' + codeLine)
            }
            .alignItems(HorizontalAlign.Start)
            .padding(10)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          // 不能用 width('100%')：父气泡是自适应宽度，百分比会形成循环依赖，
          // 结果常常是"文本不换行、被撑到屏幕外"。maxWidth 才是把约束往下传的正确写法。
          .constraintSize({ maxWidth: '100%' })
          .backgroundColor(CODE_BG)
          .borderRadius(8)
          .margin({ top: 6, bottom: 6 })

        } else if (block.kind === 'table') {
          // 表格：同样横向可滚，列宽固定
          Scroll() {
            Column() {
              ForEach(block.raw, (row: string, ri: number) => {
                Row() {
                  ForEach(splitRow(row), (cell: string, ci: number) => {
                    // 单元格内容也要走行内解析 —— 否则 **粗体** / `code` 会原样漏成源码
                    Text() {
                      ForEach(parseInline(cell), (cs: MdInline, csi: number) => {
                        Span(cs.text)
                          .fontSize(12)
                          .fontColor(cs.code ? '#b45309' : (ri === 0 ? '#1e293b' : '#334155'))
                          .fontWeight((cs.bold || ri === 0) ? FontWeight.Bold : FontWeight.Normal)
                          .fontStyle(cs.italic ? FontStyle.Italic : FontStyle.Normal)
                          .fontFamily(cs.code ? 'monospace' : '')
                      }, (cs: MdInline, csi: number) => String(csi) + '-' + cs.text)
                    }
                    .width(110)
                    // 单元格里也允许任意字符断行，否则路径/URL 这类超长 token 会溢出
                    .wordBreak(WordBreak.BREAK_WORD)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                  }, (cell: string, ci: number) => String(ci) + '-' + cell)
                }
                .backgroundColor(ri === 0 ? '#eef2f7' : '#ffffff')
                .border({ width: { bottom: 1 }, color: '#e2e8f0' })
              }, (row: string, ri: number) => String(ri) + '-' + row)
            }
            .alignItems(HorizontalAlign.Start)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Auto)
          .constraintSize({ maxWidth: '100%' })
          .borderRadius(8)
          .border({ width: 1, color: '#e2e8f0' })
          .margin({ top: 6, bottom: 6 })

        } else if (block.kind === 'rule') {
          Divider().color(this.isUser ? '#93c5fd' : '#e2e8f0').margin({ top: 8, bottom: 8 })

        } else if (block.kind === 'list') {
          // 列表：用一个 Text + 多个 Span，项之间用换行符连接
          Text() {
            ForEach(block.inline, (span: MdInline, si: number) => {
              Span(span.text)
                .fontSize(15)
                .fontColor(this.inlineColor(span))
                .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
                .fontFamily(span.code ? 'monospace' : '')
                .decoration(span.link
                  ? { type: TextDecorationType.Underline, color: this.inlineColor(span) }
                  : { type: TextDecorationType.None })
            }, (span: MdInline, si: number) => String(si) + '-' + span.text)
          }
          .lineHeight(24)
          // 关键修复：WordBreak.NORMAL 下「非 CJK 文本只能在空格处换行」，
          // 而消息里全是 D:\工程目录\src\... 、http://192.168.1.x:3100 这类
          // 没有空格的超长 token —— 它们无法断开，会把文本宽度顶出屏幕，
          // 于是整条内容被挤到可见区域之外。BREAK_WORD 允许在任意字符处断行
          //（能保住完整单词时仍然保住）。
          .wordBreak(WordBreak.BREAK_WORD)
          .textAlign(TextAlign.Start)

        } else {
          // 段落 / 标题 / 引用：同一个 Text + Span 通道
          Text() {
            ForEach(block.inline, (span: MdInline, si: number) => {
              Span(span.text)
                .fontSize(block.kind === 'h' ? this.headingSize(block.level) : 15)
                .fontColor(this.inlineColor(span))
                .fontWeight(span.bold || block.kind === 'h' ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(span.italic || block.kind === 'quote' ? FontStyle.Italic : FontStyle.Normal)
                .fontFamily(span.code ? 'monospace' : '')
                .decoration(span.link
                  ? { type: TextDecorationType.Underline, color: this.inlineColor(span) }
                  : { type: TextDecorationType.None })
            }, (span: MdInline, si: number) => String(si) + '-' + span.text)
          }
          .lineHeight(block.kind === 'h' ? 28 : 23)
          .wordBreak(WordBreak.BREAK_WORD)
          .padding(block.kind === 'quote'
            ? { left: 10, top: 4, bottom: 4 }
            : { top: block.kind === 'h' ? 6 : 0, bottom: block.kind === 'h' ? 2 : 0 })
          .border(block.kind === 'quote'
            ? { width: { left: 3 }, color: this.isUser ? '#bfdbfe' : '#cbd5e1' }
            : { width: 0 })
          .textAlign(TextAlign.Start)
        }
      }, (block: MdBlock, index: number) => String(index) + '-' + block.kind + '-' + String(block.raw.length))
    }
    // 同样不用 width('100%')：气泡是自适应宽度，百分比会循环依赖。
    // 用 maxWidth 把「最多这么宽」的约束往下传，文本就会在这个宽度内正常换行。
    .constraintSize({ maxWidth: '100%' })
    .alignItems(HorizontalAlign.Start)
    .clip(true)
  }
}
