// The full financial statements, ready for the directors to sign: Word (.docx), PDF and Excel, all drawn from the
// same model (fsPack.ts). Cover, contents, corporate information, directors' report, directors' responsibilities,
// the four primary statements with the approval and signatures, the notes, value added and the five-year summary.
import { cellText, type Block, type PackModel, type PCol, type PRow, type PSection } from './fsPack';

const INK = '111827'; const MUTED = '6B7280'; const LINE = '111827';
const isAmount = (c: PCol) => c.type === 'money' || c.type === 'pct' || c.type === 'number';
const fileType = { docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' };
const STATEMENTS = new Set(['sopl', 'sofp', 'soce', 'cash_flow']);
const INTEGRAL = 'The accompanying notes form an integral part of these financial statements.';
const frameworkLine = (m: PackModel) =>
  `Prepared in accordance with ${m.framework} as issued by the International Accounting Standards Board and adopted by the Financial Reporting Council of Nigeria, and the requirements of the Companies and Allied Matters Act 2020 and the Financial Reporting Council of Nigeria Act 2011 (as amended).`;

// ------------------------------------------------------------------ Word
export async function packDocx(m: PackModel): Promise<Blob> {
  const d = await import('docx');
  const { AlignmentType, Bookmark, BorderStyle, Document, Footer, Header, HeadingLevel, InternalHyperlink, LeaderType, Packer, PageNumber, PageOrientation, PageReference, Paragraph, Table, TableCell, TableRow, TabStopType, TextRun, WidthType } = d;
  const NONE = { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' };
  const NO_BORDERS = { top: NONE, bottom: NONE, left: NONE, right: NONE, insideHorizontal: NONE, insideVertical: NONE };
  const thin = { style: BorderStyle.SINGLE, size: 6, color: LINE };
  const dbl = { style: BorderStyle.DOUBLE, size: 6, color: LINE };
  const MARGIN = 1134; // 2 cm
  const width = (wide?: boolean) => (wide ? 16838 : 11906) - MARGIN * 2;
  const runs = (text: string, o: Record<string, unknown> = {}) => text.split('\n').map((t, i) => new TextRun({ text: t, break: i ? 1 : undefined, ...o }));
  const para = (text: string, o: { bold?: boolean; italic?: boolean; size?: number; align?: any; indent?: number; after?: number; before?: number; color?: string; keepNext?: boolean } = {}) =>
    new Paragraph({ alignment: o.align, keepNext: o.keepNext, indent: o.indent ? { left: o.indent * 360 } : undefined, spacing: { after: o.after ?? 120, before: o.before ?? 0, line: 276 },
      children: runs(text, { bold: o.bold, italics: o.italic, size: o.size, color: o.color }) });

  function table(b: Extract<Block, { t: 'table' }>, wide?: boolean) {
    const W = width(wide);
    const amountCols = b.cols.filter(isAmount).length;
    const noteW = b.cols.some((c) => c.type === 'note') ? 700 : 0;
    const amtW = Math.min(1900, Math.floor((W * (wide ? 0.62 : 0.5) - noteW) / Math.max(1, amountCols)));
    const firstW = W - noteW - amtW * amountCols;
    const widths = b.cols.map((c, i) => (i === 0 ? firstW : c.type === 'note' ? noteW : amtW));
    const head = new TableRow({ tableHeader: true, children: b.cols.map((c, i) => new TableCell({
      width: { size: widths[i], type: WidthType.DXA }, borders: { top: NONE, left: NONE, right: NONE, bottom: isAmount(c) ? thin : NONE },
      children: [new Paragraph({ alignment: isAmount(c) ? AlignmentType.RIGHT : c.type === 'note' ? AlignmentType.CENTER : AlignmentType.LEFT, children: runs(c.label, { bold: true, size: 17 }) })],
    })) });
    const body = b.rows.map((r: PRow) => {
      const st = r.style;
      const strong = st === 'heading' || st === 'subtotal' || st === 'total' || st === 'subheading';
      return new TableRow({ cantSplit: true, children: b.cols.map((c, i) => {
        const v = cellText(c, r.cells[c.key]);
        const border = isAmount(c) && (st === 'subtotal' || st === 'total') ? { top: thin, bottom: st === 'total' ? dbl : NONE, left: NONE, right: NONE } : { top: NONE, bottom: NONE, left: NONE, right: NONE };
        return new TableCell({ width: { size: widths[i], type: WidthType.DXA }, borders: border, children: [new Paragraph({
          alignment: isAmount(c) ? AlignmentType.RIGHT : c.type === 'note' ? AlignmentType.CENTER : AlignmentType.LEFT,
          indent: i === 0 && r.indent ? { left: r.indent * 284 } : undefined, spacing: { before: st === 'heading' ? 160 : 40, after: 40 },
          children: [new TextRun({ text: v, bold: strong, italics: st === 'subheading', size: st === 'heading' ? 20 : 19, color: st === 'warning' ? 'B42318' : undefined })],
        })] });
      }) });
    });
    return new Table({ width: { size: W, type: WidthType.DXA }, columnWidths: widths, borders: NO_BORDERS, rows: [head, ...body] });
  }
  function kv(items: [string, string][], wide?: boolean) {
    const W = width(wide);
    return new Table({ width: { size: W, type: WidthType.DXA }, columnWidths: [Math.round(W * 0.34), W - Math.round(W * 0.34)], borders: NO_BORDERS,
      rows: items.map(([k, v]) => new TableRow({ cantSplit: true, children: [
        new TableCell({ borders: NO_BORDERS, children: [para(k, { bold: true, after: 80 })] }),
        new TableCell({ borders: NO_BORDERS, children: v.split('\n').map((line) => para(line, { after: 80 })) }),
      ] })) });
  }
  function sign(items: { name: string; role: string }[], wide?: boolean) {
    const W = width(wide);
    const cells = items.map((s) => new TableCell({ borders: NO_BORDERS, width: { size: Math.floor(W / Math.max(2, items.length)), type: WidthType.DXA }, children: [
      new Paragraph({ spacing: { before: 720, after: 0 }, children: [new TextRun({ text: '........................................................', color: MUTED })] }),
      para(s.name || ' ', { bold: true, after: 0, before: 60 }), para(s.role, { size: 18, color: MUTED, after: 120 }),
    ] }));
    return new Table({ width: { size: W, type: WidthType.DXA }, borders: NO_BORDERS, rows: [new TableRow({ cantSplit: true, children: cells })] });
  }
  function blocks(s: PSection) {
    const out: (InstanceType<typeof Paragraph> | InstanceType<typeof Table>)[] = [];
    for (const b of s.blocks) {
      if (b.t === 'heading') out.push(new Paragraph({ heading: b.level === 2 ? HeadingLevel.HEADING_2 : HeadingLevel.HEADING_3, keepNext: true, children: [new TextRun(b.text)] }));
      else if (b.t === 'para') out.push(para(b.text, { indent: b.indent, align: AlignmentType.JUSTIFIED, keepNext: s.blocks[s.blocks.indexOf(b) + 1]?.t === 'sign' }));
      else if (b.t === 'table') { out.push(table(b, s.wide)); out.push(para('', { after: 60 })); }
      else if (b.t === 'kv') out.push(kv(b.items, s.wide));
      else if (b.t === 'sign') { out.push(sign(b.items, s.wide)); out.push(para('Date: ........................................', { before: 120, color: MUTED })); }
    }
    if (STATEMENTS.has(s.key)) out.push(para(INTEGRAL, { italic: true, size: 17, color: MUTED, before: 160 }));
    return out;
  }
  const header = () => new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [new TextRun({ text: m.orgName, size: 16, color: MUTED })] })] });
  const footer = () => new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
    new TextRun({ text: `${m.reportTitle} ${m.periodText} · Page `, size: 16, color: MUTED }), new TextRun({ children: [PageNumber.CURRENT], size: 16, color: MUTED }),
  ] })] });
  const page = (wide?: boolean) => ({ size: { orientation: wide ? PageOrientation.LANDSCAPE : PageOrientation.PORTRAIT }, margin: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN } });

  const cover = {
    properties: { page: page() },
    children: [
      para(m.orgName, { bold: true, size: 52, before: 2600, after: 240, color: INK }),
      ...m.legal.map((l) => para(l, { size: 20, color: MUTED, after: 40 })),
      para(m.reportTitle, { bold: true, size: 40, before: 900, after: 120 }),
      para(m.periodText.replace(/^f/, 'F'), { size: 26, after: 600 }),
      para(frameworkLine(m), { size: 18, color: MUTED }),
    ],
  };
  const contents = {
    properties: { page: page() }, headers: { default: header() }, footers: { default: footer() },
    children: [
      para('Contents', { bold: true, size: 30, after: 240 }),
      ...m.sections.map((s) => new Paragraph({
        tabStops: [{ type: TabStopType.RIGHT, position: width(), leader: LeaderType.DOT }], spacing: { after: 140 },
        children: [new InternalHyperlink({ anchor: `sec_${s.key}`, children: [new TextRun({ text: s.title, size: 21 })] }), new TextRun({ text: '\t', size: 21 }),
          new PageReference(`sec_${s.key}`)],
      })),
    ],
  };
  const sections = m.sections.map((s) => ({
    properties: { page: page(s.wide) }, headers: { default: header() }, footers: { default: footer() },
    children: [
      new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new Bookmark({ id: `sec_${s.key}`, children: [new TextRun(s.title)] })] }),
      ...(s.subtitle ? [para(s.subtitle, { italic: true, color: MUTED, after: 240 })] : [para('', { after: 120 })]),
      ...blocks(s),
    ],
  }));
  const doc = new Document({
    creator: 'Counta · TaxStreem', title: `${m.orgName} ${m.reportTitle} ${m.periodText}`, description: 'Financial statements generated by Counta',
    features: { updateFields: true },
    styles: {
      default: { document: { run: { font: 'Arial', size: 20, color: '1F2937' } } },
      paragraphStyles: [
        { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { font: 'Arial', size: 30, bold: true, color: INK }, paragraph: { spacing: { after: 60 } } },
        { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { font: 'Arial', size: 23, bold: true, color: INK }, paragraph: { spacing: { before: 280, after: 100 }, keepNext: true } },
        { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { font: 'Arial', size: 20, bold: true, color: '374151' }, paragraph: { spacing: { before: 200, after: 80 }, keepNext: true } },
      ],
    },
    sections: [cover, contents, ...sections],
  });
  const blob = await Packer.toBlob(doc);
  return new Blob([blob], { type: fileType.docx });
}

// ------------------------------------------------------------------ PDF
// jsPDF's standard fonts cover Latin-1 only: the naira sign prints as N, dashes and quotes as their plain forms.
const pdfSafe = (s: string) => String(s)
  .replace(/₦/g, 'N').replace(/[−–—]/g, '-').replace(/[‘’]/g, "'").replace(/[“”]/g, '"').replace(/…/g, '...').replace(/•/g, '-')
  .replace(/[^\u0000-ÿ]/g, (ch) => { const base = ch.normalize('NFD')[0]; return base && base.charCodeAt(0) <= 0xff ? base : '?'; });

export async function packPdf(m: PackModel): Promise<Blob> {
  const [{ jsPDF }, { autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'pt', format: 'a4', orientation: 'portrait' });
  const M = 54; const BOTTOM = 60;
  const W = () => doc.internal.pageSize.getWidth();
  const H = () => doc.internal.pageSize.getHeight();
  let wide = false;
  let y = M;
  const newPage = () => { doc.addPage('a4', wide ? 'landscape' : 'portrait'); y = M; };
  const ensure = (h: number) => { if (y + h > H() - BOTTOM) newPage(); };
  const text = (s: string, o: { size?: number; bold?: boolean; italic?: boolean; color?: [number, number, number]; indent?: number; gap?: number; align?: 'justify' | 'left' } = {}) => {
    const size = o.size ?? 9.5;
    doc.setFont('helvetica', o.bold && o.italic ? 'bolditalic' : o.bold ? 'bold' : o.italic ? 'italic' : 'normal');
    doc.setFontSize(size); doc.setTextColor(...(o.color || [31, 41, 55]));
    const x = M + (o.indent || 0) * 14;
    const lines: string[] = doc.splitTextToSize(pdfSafe(s), W() - x - M);
    const lh = size * 1.38;
    lines.forEach((ln, i) => {
      ensure(lh);
      const last = i === lines.length - 1;
      doc.text(ln, x, y + size, o.align === 'justify' && !last ? { maxWidth: W() - x - M, align: 'justify' } : {});
      y += lh;
    });
    y += o.gap ?? 5;
  };

  // Cover
  doc.setFillColor(17, 24, 39); doc.rect(0, 0, W(), 8, 'F');
  y = 230;
  text(m.orgName, { size: 26, bold: true, color: [17, 24, 39], gap: 10 });
  m.legal.forEach((l) => text(l, { size: 10, color: [107, 114, 128], gap: 2 }));
  y += 90;
  text(m.reportTitle, { size: 20, bold: true, gap: 6 });
  text(m.periodText.replace(/^f/, 'F'), { size: 13, gap: 40 });
  text(frameworkLine(m), { size: 9, color: [107, 114, 128] });

  // Contents goes on page 2 once page numbers are known.
  doc.addPage('a4', 'portrait');
  const contentsPage = doc.getNumberOfPages();
  const starts: { title: string; page: number }[] = [];

  for (const s of m.sections) {
    wide = !!s.wide;
    newPage();
    starts.push({ title: s.title, page: doc.getNumberOfPages() });
    text(m.orgName, { size: 9, color: [107, 114, 128], gap: 2 });
    text(s.title, { size: 15, bold: true, color: [17, 24, 39], gap: 2 });
    if (s.subtitle) text(s.subtitle, { size: 9.5, italic: true, color: [107, 114, 128], gap: 12 }); else y += 8;
    for (const b of s.blocks) {
      if (b.t === 'heading') { ensure(40); y += b.level === 2 ? 8 : 4; text(b.text, { size: b.level === 2 ? 11.5 : 10, bold: true, color: [17, 24, 39], gap: 3 }); }
      else if (b.t === 'para') {
        if (s.blocks[s.blocks.indexOf(b) + 1]?.t === 'sign') ensure(130);
        text(b.text, { indent: b.indent, align: 'justify' });
      }
      else if (b.t === 'kv') {
        autoTable(doc as any, {
          startY: y, margin: { left: M, right: M, bottom: BOTTOM }, theme: 'plain', styles: { fontSize: 9.5, cellPadding: { top: 3, bottom: 3, left: 0, right: 8 }, textColor: [31, 41, 55] },
          columnStyles: { 0: { fontStyle: 'bold', cellWidth: (W() - 2 * M) * 0.34 } }, body: b.items.map(([k, v]) => [pdfSafe(k), pdfSafe(v)]),
        });
        y = (doc as any).lastAutoTable.finalY + 10;
      } else if (b.t === 'sign') {
        ensure(110);
        const colW = (W() - 2 * M) / Math.max(2, b.items.length);
        b.items.forEach((it, i) => {
          const x = M + i * colW;
          doc.setDrawColor(107, 114, 128); doc.setLineDashPattern([1, 2], 0); doc.line(x, y + 46, x + colW - 30, y + 46); doc.setLineDashPattern([], 0);
          doc.setFont('helvetica', 'bold'); doc.setFontSize(9.5); doc.setTextColor(17, 24, 39); doc.text(pdfSafe(it.name), x, y + 60, { maxWidth: colW - 30 });
          doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(107, 114, 128); doc.text(pdfSafe(it.role), x, y + 72, { maxWidth: colW - 30 });
        });
        y += 88;
        text('Date: ........................................', { size: 9, color: [107, 114, 128], gap: 8 });
      } else if (b.t === 'table') {
        const cols = b.cols;
        const avail = W() - 2 * M;
        const nAmt = cols.filter(isAmount).length;
        const noteW = cols.some((c) => c.type === 'note') ? 34 : 0;
        const amtW = Math.min(96, (avail * (wide ? 0.62 : 0.5) - noteW) / Math.max(1, nAmt));
        autoTable(doc as any, {
          startY: y, margin: { left: M, right: M, bottom: BOTTOM }, theme: 'plain', showHead: 'everyPage', rowPageBreak: 'avoid',
          styles: { fontSize: 8.8, cellPadding: { top: 2.6, bottom: 2.6, left: 3, right: 3 }, textColor: [31, 41, 55], overflow: 'linebreak', valign: 'bottom' },
          headStyles: { fontStyle: 'bold', textColor: [17, 24, 39], fontSize: 8.3 },
          columnStyles: Object.fromEntries(cols.map((c, i) => [i, {
            halign: isAmount(c) ? 'right' : c.type === 'note' ? 'center' : 'left',
            cellWidth: i === 0 ? 'auto' : c.type === 'note' ? noteW : amtW,
          }])) as any,
          head: [cols.map((c) => pdfSafe(c.label))],
          body: b.rows.map((r) => cols.map((c) => pdfSafe(cellText(c, r.cells[c.key])))),
          didParseCell: (h: any) => {
            if (h.section === 'head') { h.cell.styles.halign = isAmount(cols[h.column.index]) ? 'right' : cols[h.column.index].type === 'note' ? 'center' : 'left'; return; }
            const r = b.rows[h.row.index]; if (!r) return;
            const st = r.style;
            if (st === 'heading' || st === 'subtotal' || st === 'total') h.cell.styles.fontStyle = 'bold';
            if (st === 'subheading') h.cell.styles.fontStyle = 'bolditalic';
            if (st === 'heading') { h.cell.styles.fontSize = 9.5; h.cell.styles.cellPadding = { top: 7, bottom: 2.6, left: 3, right: 3 }; }
            if (st === 'warning') h.cell.styles.textColor = [180, 35, 24];
            if (h.column.index === 0 && r.indent) h.cell.styles.cellPadding = { ...(typeof h.cell.styles.cellPadding === 'object' ? h.cell.styles.cellPadding : {}), left: 3 + r.indent * 12 };
          },
          didDrawCell: (h: any) => {
            const c = cols[h.column.index];
            if (!isAmount(c)) return;
            doc.setDrawColor(17, 24, 39); doc.setLineWidth(0.6);
            const x1 = h.cell.x + 6, x2 = h.cell.x + h.cell.width - 3;
            if (h.section === 'head') { doc.line(x1, h.cell.y + h.cell.height, x2, h.cell.y + h.cell.height); return; }
            const r = b.rows[h.row.index]; if (!r) return;
            if (r.style === 'subtotal' || r.style === 'total') doc.line(x1, h.cell.y + 1, x2, h.cell.y + 1);
            if (r.style === 'total') { const yb = h.cell.y + h.cell.height - 1; doc.line(x1, yb, x2, yb); doc.line(x1, yb + 2, x2, yb + 2); }
          },
        });
        y = (doc as any).lastAutoTable.finalY + 10;
      }
    }
    if (STATEMENTS.has(s.key)) { y += 6; text(INTEGRAL, { size: 8.5, italic: true, color: [107, 114, 128] }); }
  }

  // Contents with page numbers
  doc.setPage(contentsPage);
  y = M; wide = false;
  doc.setFont('helvetica', 'bold'); doc.setFontSize(9); doc.setTextColor(107, 114, 128); doc.text(pdfSafe(m.orgName), M, y + 9); y += 22;
  doc.setFontSize(16); doc.setTextColor(17, 24, 39); doc.text('Contents', M, y + 16); y += 40;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10.5);
  for (const st of starts) {
    const label = pdfSafe(st.title);
    doc.setTextColor(31, 41, 55); doc.text(label, M, y);
    doc.text(String(st.page), W() - M, y, { align: 'right' });
    const lw = doc.getTextWidth(label) + 6, nw = doc.getTextWidth(String(st.page)) + 6;
    doc.setTextColor(180, 180, 180); let dots = ''; while (doc.getTextWidth(dots + ' .') < W() - 2 * M - lw - nw) dots += ' .';
    doc.text(dots, M + lw, y);
    y += 22;
  }
  // Footers
  const n = doc.getNumberOfPages();
  for (let i = 2; i <= n; i++) {
    doc.setPage(i);
    doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(107, 114, 128);
    doc.text(pdfSafe(`${m.orgName} · ${m.reportTitle} ${m.periodText}`), M, doc.internal.pageSize.getHeight() - 28);
    doc.text(`Page ${i}`, doc.internal.pageSize.getWidth() - M, doc.internal.pageSize.getHeight() - 28, { align: 'right' });
  }
  return doc.output('blob');
}

// ------------------------------------------------------------------ Excel
export async function packXlsx(m: PackModel): Promise<Blob> {
  const mod: any = await import('exceljs');
  const ExcelJS = (mod.default || mod) as typeof import('exceljs');
  const wb = new ExcelJS.Workbook();
  wb.creator = 'Counta · TaxStreem'; wb.created = new Date();
  const ACC = '#,##0.00;(#,##0.00);"–"';
  const sheetName = (s: string) => s.replace(/[*?:\\/[\]']/g, '').slice(0, 31);
  const names = new Map<string, string>();
  m.sections.forEach((s) => names.set(s.key, sheetName(SHEET[s.key] || s.title)));

  const cover = wb.addWorksheet('Cover', { pageSetup: { paperSize: 9, orientation: 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0 } });
  cover.getColumn(1).width = 110;
  const put = (ws: any, r: number, v: string, font: Record<string, unknown>, wrap = false) => { const c = ws.getCell(r, 1); c.value = v; c.font = font; if (wrap) c.alignment = { wrapText: true, vertical: 'top' }; };
  put(cover, 2, m.orgName, { bold: true, size: 20, color: { argb: 'FF' + INK } });
  m.legal.forEach((l, i) => put(cover, 3 + i, l, { size: 10, color: { argb: 'FF' + MUTED } }));
  put(cover, 7, m.reportTitle, { bold: true, size: 16 });
  put(cover, 8, m.periodText.replace(/^f/, 'F'), { size: 12 });
  put(cover, 10, frameworkLine(m), { size: 9, color: { argb: 'FF' + MUTED } }, true); cover.getRow(10).height = 56;
  put(cover, 12, 'Contents', { bold: true, size: 12 });
  m.sections.forEach((s, i) => {
    const c = cover.getCell(13 + i, 1);
    c.value = { text: s.title, hyperlink: `#'${names.get(s.key)}'!A1` } as any;
    c.font = { color: { argb: 'FF0072F5' }, underline: true };
  });

  for (const s of m.sections) {
    const tables = s.blocks.filter((b) => b.t === 'table') as Extract<Block, { t: 'table' }>[];
    const nCols = Math.max(2, ...tables.map((t) => t.cols.length));
    const ws = wb.addWorksheet(names.get(s.key)!, {
      pageSetup: { paperSize: 9, orientation: s.wide || nCols > 5 ? 'landscape' : 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0,
        margins: { left: 0.6, right: 0.6, top: 0.7, bottom: 0.7, header: 0.3, footer: 0.3 } },
      headerFooter: { oddFooter: `&L${xlEsc(m.orgName)}&R&P of &N`, oddHeader: `&R${xlEsc(s.title)}` },
      views: [{ showGridLines: false }],
    });
    ws.getColumn(1).width = s.key === 'corporate' ? 34 : 62;
    for (let i = 2; i <= nCols; i++) ws.getColumn(i).width = s.key === 'corporate' ? 70 : 17;
    let r = 1;
    const merged = (text: string, font: Record<string, unknown>, opts: { wrap?: boolean; indent?: number; height?: number } = {}) => {
      ws.mergeCells(r, 1, r, nCols);
      const c = ws.getCell(r, 1); c.value = text; c.font = font;
      c.alignment = { wrapText: opts.wrap ?? true, vertical: 'top', indent: opts.indent };
      if (opts.height) ws.getRow(r).height = opts.height;
      else if (opts.wrap !== false) ws.getRow(r).height = Math.max(15, 13.5 * Math.ceil(text.length / (s.key === 'corporate' ? 120 : 110 + (nCols - 2) * 18)));
      r++;
    };
    merged(m.orgName, { bold: true, size: 13, color: { argb: 'FF' + INK } }, { wrap: false });
    merged(s.title, { bold: true, size: 12 }, { wrap: false });
    if (s.subtitle) merged(s.subtitle, { italic: true, size: 10, color: { argb: 'FF' + MUTED } }, { wrap: false });
    r++;
    for (const b of s.blocks) {
      if (b.t === 'heading') { r += b.level === 2 ? 1 : 0; merged(b.text, { bold: true, size: b.level === 2 ? 11.5 : 10.5 }, { wrap: false }); }
      else if (b.t === 'para') merged(b.text, { size: 10 }, { indent: b.indent ? b.indent * 2 : undefined });
      else if (b.t === 'kv') {
        for (const [k, v] of b.items) {
          ws.getCell(r, 1).value = k; ws.getCell(r, 1).font = { bold: true }; ws.getCell(r, 1).alignment = { vertical: 'top', wrapText: true };
          if (nCols > 2) ws.mergeCells(r, 2, r, nCols);
          ws.getCell(r, 2).value = v; ws.getCell(r, 2).alignment = { wrapText: true, vertical: 'top' };
          ws.getRow(r).height = Math.max(15, 14 * v.split('\n').length, 13.5 * Math.ceil(v.length / 90));
          r++;
        }
        r++;
      } else if (b.t === 'sign') {
        r++;
        b.items.forEach((it, i) => {
          const col = 1 + i * Math.max(1, Math.floor(nCols / 2));
          ws.getCell(r, col).value = '................................................'; ws.getCell(r, col).font = { color: { argb: 'FF' + MUTED } };
          ws.getCell(r + 1, col).value = it.name; ws.getCell(r + 1, col).font = { bold: true };
          ws.getCell(r + 2, col).value = it.role; ws.getCell(r + 2, col).font = { size: 9, color: { argb: 'FF' + MUTED } };
        });
        ws.getRow(r).height = 36; ws.getRow(r).alignment = { vertical: 'bottom' };
        r += 4;
        ws.getCell(r, 1).value = 'Date: ........................................'; ws.getCell(r, 1).font = { color: { argb: 'FF' + MUTED } };
        r += 2;
      } else if (b.t === 'table') {
        const head = ws.getRow(r);
        b.cols.forEach((c, i) => {
          const cell = head.getCell(i + 1);
          cell.value = c.label; cell.font = { bold: true, size: 9.5 };
          cell.alignment = { wrapText: true, vertical: 'bottom', horizontal: isAmount(c) ? 'right' : c.type === 'note' ? 'center' : 'left' };
          if (isAmount(c)) cell.border = { bottom: { style: 'thin', color: { argb: 'FF' + LINE } } };
        });
        head.height = 28; r++;
        for (const row of b.rows) {
          const xr = ws.getRow(r);
          const st = row.style;
          b.cols.forEach((c, i) => {
            const cell = xr.getCell(i + 1);
            const v = row.cells[c.key];
            if (isAmount(c)) {
              const nv = v === null || v === undefined || v === '' ? null : Number(v);
              cell.value = nv === null || !Number.isFinite(nv) ? null : c.type === 'pct' ? nv / 100 : nv;
              cell.numFmt = c.type === 'pct' ? '0.0%' : ACC;
              cell.alignment = { horizontal: 'right' };
              if (st === 'subtotal' || st === 'total') cell.border = { top: { style: 'thin', color: { argb: 'FF' + LINE } }, ...(st === 'total' ? { bottom: { style: 'double', color: { argb: 'FF' + LINE } } } : {}) };
            } else {
              cell.value = v === null || v === undefined ? null : String(v);
              cell.alignment = { horizontal: c.type === 'note' ? 'center' : 'left', indent: i === 0 && row.indent ? row.indent * 2 : undefined, wrapText: i === 0, vertical: 'top' };
            }
          });
          if (st === 'heading' || st === 'subtotal' || st === 'total') xr.font = { bold: true };
          if (st === 'subheading') xr.font = { bold: true, italic: true };
          if (st === 'warning') xr.font = { color: { argb: 'FFB42318' } };
          r++;
        }
        r++;
      }
    }
    if (STATEMENTS.has(s.key)) merged(INTEGRAL, { italic: true, size: 9, color: { argb: 'FF' + MUTED } }, { wrap: false });
  }
  const buf = await wb.xlsx.writeBuffer();
  return new Blob([buf], { type: fileType.xlsx });
}
const xlEsc = (s: string) => s.replace(/&/g, '&&');
const SHEET: Record<string, string> = {
  corporate: 'Corporate information', directors_report: "Directors report", responsibilities: "Directors responsibilities", sopl: 'Profit or loss and OCI',
  sofp: 'Financial position', soce: 'Changes in equity', cash_flow: 'Cash flows', notes: 'Notes', value_added: 'Value added', five_year: 'Five-year summary',
};
