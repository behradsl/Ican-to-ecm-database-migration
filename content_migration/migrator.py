import os
import pyodbc
import hashlib
import uuid
import re
import pandas as pd
import jdatetime
from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH
from bs4 import BeautifulSoup

# Import our centralized config and db utilities
import config
from db_utils import get_ican_conn, get_rahkaran_conn, get_sqlalchemy_engine

import xml.etree.ElementTree as ET

DOCX_CONTENT_TYPE = (
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
)
PDF_CONTENT_TYPE = "application/pdf"

CONTENT_FORMAT_META = {
    "pdf": {
        "ext": "pdf",
        "ext_dot": ".pdf",
        "content_type": PDF_CONTENT_TYPE,
        "dir_attr": "PDF_DIR",
        "label": "PDF",
    },
    "docx": {
        "ext": "docx",
        "ext_dot": ".docx",
        "content_type": DOCX_CONTENT_TYPE,
        "dir_attr": "DOCX_DIR",
        "label": "DOCX",
    },
}


def normalize_content_format(content_format: str) -> str:
    fmt = (content_format or "").strip().lower()
    if fmt not in CONTENT_FORMAT_META:
        raise ValueError(f"Unsupported content format: {content_format!r}. Use 'pdf' or 'docx'.")
    return fmt


def get_content_format_meta(content_format: str):
    fmt = normalize_content_format(content_format)
    meta = dict(CONTENT_FORMAT_META[fmt])
    meta["output_dir"] = getattr(config, meta["dir_attr"])
    return meta


def _safe_letter_filename(number: str) -> str:
    """Sanitize a letter number for use in filesystem names."""
    return re.sub(r'[\\/*?:"<>|]', '-', str(number).strip())


def _load_registration_by_entity_code():
    """
    Map ICAN EntityCode -> registration number / date from Rahkaran letters
    (populated by step 7 from import/export). Falls back to empty dict if map missing.
    """
    try:
        engine = get_sqlalchemy_engine(config.RAHKARAN_DB)
        query = f"""
            SELECT
                M.Ican_EntityCode,
                L.RegistrationNumber,
                L.RegistrationDate
            FROM master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
            INNER JOIN [{config.RAHKARAN_DB}].ECM.Letter L
                ON L.LetterID = M.Rahkaran_LetterID
        """
        df = pd.read_sql(query, engine)
        lookup = {}
        for _, row in df.iterrows():
            code = int(row['Ican_EntityCode'])
            reg_no = row['RegistrationNumber']
            if pd.isna(reg_no) or str(reg_no).strip() == '':
                continue
            lookup[code] = {
                'RegistrationNumber': str(reg_no).strip(),
                'RegistrationDate': row['RegistrationDate'] if pd.notna(row['RegistrationDate']) else None,
            }
        print(f"Loaded {len(lookup)} registration numbers from Rahkaran letter map.")
        return lookup
    except Exception as e:
        print(f"⚠️ Could not load Rahkaran registration numbers ({e}). Falling back to ICAN EntityNumber.")
        return {}


def _format_shamsi_date(raw_date) -> str:
    if raw_date is None or (isinstance(raw_date, float) and pd.isna(raw_date)):
        return ''
    if pd.isna(raw_date):
        return ''
    try:
        gregorian_date = raw_date.date() if hasattr(raw_date, 'date') else pd.to_datetime(str(raw_date)).date()
        jalali_date = jdatetime.date.fromgregorian(date=gregorian_date)
        return jalali_date.strftime("%Y/%m/%d")
    except Exception:
        return str(raw_date).split(' ')[0]


def step_1_extract_html():
    print("\n" + "="*50)
    print("PHASE 2, STEP 1: EXTRACTING ICAN LETTERS TO HTML")
    print("="*50)
    
    html_template = """
    <!DOCTYPE html>
    <html lang="fa" dir="rtl">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>{subject}</title>
        <style>
            @font-face {{ font-family: 'B Nazanin'; src: local('B Nazanin'), local('BNazanin'); }}
            body {{ font-family: 'B Nazanin', Tahoma, Arial, sans-serif; font-size: 14pt; line-height: 1.8; padding: 40px; background-color: #ffffff; color: #000000; }}
            .header {{ text-align: left; font-size: 11pt; margin-bottom: 30px; border-bottom: 2px solid #333; padding-bottom: 10px; }}
            .subject {{ font-weight: bold; margin-bottom: 20px; font-size: 15pt; }}
            .content {{ text-align: justify; min-height: 200px; }}
            .receivers-section {{ margin-top: 50px; padding-top: 20px; border-top: 2px dashed #aaa; font-size: 13pt; }}
            .receivers-section ul {{ list-style-type: square; padding-right: 20px; }}
            .receivers-section li {{ margin-bottom: 10px; }}
        </style>
    </head>
    <body>
        <div class="header">شماره نامه: {entity_number}<br>تاریخ: {date}</div>
        <div class="subject">موضوع: {subject}</div>
        <div class="content">{body_html}</div>
        {receivers_html}
    </body>
    </html>
    """

    BATCH_SIZE = 1        
    offset = 0
    processed_count = 0
    reg_lookup = _load_registration_by_entity_code()

    try:
        conn = get_ican_conn()
        cursor = conn.cursor()
        cursor.execute(f"SELECT COUNT(*) FROM {config.ICAN_DB}.dbo.Entity_public_letter")
        total_records = cursor.fetchone()[0]
        conn.close() 
        
        print(f"Total letters to extract: {total_records}")

        while offset < total_records:
            try:
                conn = get_ican_conn()
                cursor = conn.cursor()
                
                query = f"""
                    SELECT EntityCode, EntityNumber, Subject, CreationDate, Text, Receivers 
                    FROM {config.ICAN_DB}.dbo.Entity_public_letter
                    ORDER BY EntityNumber 
                    OFFSET {offset} ROWS 
                    FETCH NEXT {BATCH_SIZE} ROWS ONLY
                """
                cursor.execute(query)
                rows = cursor.fetchall()
                
                if not rows:
                    conn.close()
                    break
                    
                columns = [column[0] for column in cursor.description]
                df = pd.DataFrame.from_records(rows, columns=columns)
                
                for index, row in df.iterrows():
                    entity_code = int(row['EntityCode']) if pd.notna(row.get('EntityCode')) else None
                    internal_number = str(row.get('EntityNumber', 'Unknown'))
                    subject = str(row.get('Subject', 'بدون موضوع'))

                    reg_info = reg_lookup.get(entity_code) if entity_code is not None else None
                    display_number = (
                        reg_info['RegistrationNumber']
                        if reg_info else internal_number
                    )

                    raw_date = (
                        reg_info['RegistrationDate']
                        if reg_info and reg_info.get('RegistrationDate') is not None
                        else row.get('CreationDate', None)
                    )
                    shamsi_date_str = _format_shamsi_date(raw_date)
                    
                    raw_text = row.get('Text', '')
                    body_html = str(raw_text) if pd.notna(raw_text) else ''

                    raw_receivers = row.get('Receivers', None)
                    receivers_html = ""
                    
                    if pd.notna(raw_receivers) and str(raw_receivers).strip():
                        try:
                            root = ET.fromstring(str(raw_receivers))
                            captions = []
                            for receiver in root.findall('Receiver'):
                                caption = receiver.get('Caption')
                                if caption:
                                    captions.append(caption)
                                    
                            if captions:
                                lis = "".join([f"<li>{c}</li>" for c in captions])
                                receivers_html = f'<div class="receivers-section"><strong>گیرندگان:</strong><ul>{lis}</ul></div>'
                        except Exception as xml_err:
                            print(f"⚠️ XML Parse Warning for letter {display_number}: {xml_err}")
                            pass

                    safe_filename = _safe_letter_filename(display_number)
                    final_html = html_template.format(
                        subject=subject, 
                        entity_number=display_number, 
                        date=shamsi_date_str, 
                        body_html=body_html,
                        receivers_html=receivers_html
                    )

                    file_path = os.path.join(config.HTML_DIR, f'letter_{safe_filename}.html')
                    with open(file_path, 'w', encoding='utf-8-sig') as f:
                        f.write(final_html)
                        
                    processed_count += 1
                
                conn.close() 
                if (offset + 1) % 100 == 0: print(f"✅ Extracted {offset + 1} HTML files...")
                offset += BATCH_SIZE

            except Exception as e:
                print(f"⚠️ Skipping corrupted record at offset {offset}. Error: {e}")
                if 'conn' in locals() and conn:
                    try: conn.close() 
                    except: pass
                offset += BATCH_SIZE

        print(f"🎉 Step 1 Complete. Generated {processed_count} HTML files.")
    except Exception as e:
        print(f"❌ Step 1 Failed: {e}")
        raise


DOCX_FONT = "B Nazanin"


def _set_paragraph_rtl(paragraph):
    """Mark a paragraph as right-to-left (Persian letters)."""
    pPr = paragraph._p.get_or_add_pPr()
    bidi = pPr.find(qn('w:bidi'))
    if bidi is None:
        bidi = OxmlElement('w:bidi')
        pPr.append(bidi)
    bidi.set(qn('w:val'), '1')


def _set_run_font(run, size_pt: float, bold: bool = False):
    run.bold = bold
    run.font.size = Pt(size_pt)
    run.font.name = DOCX_FONT
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.find(qn('w:rFonts'))
    if rFonts is None:
        rFonts = OxmlElement('w:rFonts')
        rPr.append(rFonts)
    for attr in ('w:ascii', 'w:hAnsi', 'w:eastAsia', 'w:cs'):
        rFonts.set(qn(attr), DOCX_FONT)
    rtl = rPr.find(qn('w:rtl'))
    if rtl is None:
        rtl = OxmlElement('w:rtl')
        rPr.append(rtl)
    rtl.set(qn('w:val'), '1')


def _set_paragraph_spacing(paragraph, before_pt=0, after_pt=8, line_spacing=1.8):
    pf = paragraph.paragraph_format
    pf.space_before = Pt(before_pt)
    pf.space_after = Pt(after_pt)
    pf.line_spacing = line_spacing


def _add_paragraph_border(paragraph, edge: str, val: str = 'single', sz: str = '12', color: str = '333333'):
    """Add a paragraph border (top/bottom/left/right). sz is eighths of a point."""
    pPr = paragraph._p.get_or_add_pPr()
    pBdr = pPr.find(qn('w:pBdr'))
    if pBdr is None:
        pBdr = OxmlElement('w:pBdr')
        pPr.append(pBdr)
    border = OxmlElement(f'w:{edge}')
    border.set(qn('w:val'), val)
    border.set(qn('w:sz'), sz)
    border.set(qn('w:space'), '4')
    border.set(qn('w:color'), color)
    # replace existing edge if present
    old = pBdr.find(qn(f'w:{edge}'))
    if old is not None:
        pBdr.remove(old)
    pBdr.append(border)


def _apply_default_font(doc: Document):
    style = doc.styles['Normal']
    style.font.name = DOCX_FONT
    style.font.size = Pt(14)
    rPr = style._element.get_or_add_rPr()
    rFonts = rPr.find(qn('w:rFonts'))
    if rFonts is None:
        rFonts = OxmlElement('w:rFonts')
        rPr.append(rFonts)
    for attr in ('w:ascii', 'w:hAnsi', 'w:eastAsia', 'w:cs'):
        rFonts.set(qn(attr), DOCX_FONT)
    # Default paragraph direction RTL for Persian letters
    pPr = style._element.get_or_add_pPr()
    bidi = pPr.find(qn('w:bidi'))
    if bidi is None:
        bidi = OxmlElement('w:bidi')
        pPr.append(bidi)
    bidi.set(qn('w:val'), '1')
    jc = pPr.find(qn('w:jc'))
    if jc is None:
        jc = OxmlElement('w:jc')
        pPr.append(jc)
    jc.set(qn('w:val'), 'right')


def _set_document_page(doc: Document):
    """RTL page + margins similar to HTML padding: 40px (~1.1cm)."""
    for section in doc.sections:
        section.top_margin = Cm(1.5)
        section.bottom_margin = Cm(1.5)
        section.left_margin = Cm(1.5)
        section.right_margin = Cm(1.5)
        sectPr = section._sectPr
        bidi = sectPr.find(qn('w:bidi'))
        if bidi is None:
            bidi = OxmlElement('w:bidi')
            sectPr.append(bidi)
        bidi.set(qn('w:val'), '1')


def _add_styled_paragraph(
    doc: Document,
    text: str,
    *,
    size_pt: float = 14,
    bold: bool = False,
    align=WD_ALIGN_PARAGRAPH.RIGHT,
    before_pt: float = 0,
    after_pt: float = 8,
    border_bottom: bool = False,
    border_top_dashed: bool = False,
):
    text = (text or '').strip()
    if not text:
        return None
    p = doc.add_paragraph()
    p.alignment = align
    _set_paragraph_spacing(p, before_pt=before_pt, after_pt=after_pt)
    _set_paragraph_rtl(p)
    # Keep multi-line blocks (header date/number) as soft line breaks
    lines = text.split('\n')
    for i, line in enumerate(lines):
        run = p.add_run(line)
        _set_run_font(run, size_pt, bold=bold)
        if i < len(lines) - 1:
            run.add_break()
    if border_bottom:
        _add_paragraph_border(p, 'bottom', val='single', sz='18', color='333333')
    if border_top_dashed:
        _add_paragraph_border(p, 'top', val='dashed', sz='12', color='AAAAAA')
    return p


def _flatten_tables_in_soup(soup: BeautifulSoup):
    for table in list(soup.find_all('table')):
        wrapper = soup.new_tag('div')
        for tr in table.find_all('tr'):
            cells = [c.get_text(' ', strip=True) for c in tr.find_all(['td', 'th'])]
            cells = [c for c in cells if c]
            if not cells:
                continue
            p = soup.new_tag('p')
            p.string = ' | '.join(cells)
            wrapper.append(p)
        table.replace_with(wrapper)


def _element_text_with_breaks(el) -> str:
    """Get element text, turning <br> into newlines."""
    for br in el.find_all('br'):
        br.replace_with('\n')
    text = el.get_text('', strip=False)
    # Collapse whitespace per line but keep intentional line breaks
    lines = [re.sub(r'[ \t\u00a0]+', ' ', ln).strip() for ln in text.splitlines()]
    return '\n'.join(ln for ln in lines if ln).strip()


def _iter_content_blocks(content_el):
    """Yield leaf text blocks from the letter body (no wrapper duplicates)."""
    if content_el is None:
        return

    block_tags = ('p', 'li', 'div')
    leaves = []
    for block in content_el.find_all(block_tags, recursive=True):
        # Skip containers that wrap other block elements
        if block.find(block_tags) is not None:
            continue
        leaves.append(block)

    seen = []
    for block in leaves:
        text = _element_text_with_breaks(block)
        if text and text not in seen:
            seen.append(text)
            yield text

    if not seen:
        text = _element_text_with_breaks(content_el)
        if text:
            yield text


def _html_to_docx_document(html_content: str) -> Document:
    """
    Build a styled DOCX that mirrors the HTML letter template (all sections RTL):
    header (11pt, right, bottom border), subject (15pt bold),
    content (14pt justify), receivers (13pt, top dashed border).
    """
    soup = BeautifulSoup(html_content, 'html.parser')
    for tag in soup(['script', 'style']):
        tag.decompose()
    _flatten_tables_in_soup(soup)

    header_el = soup.select_one('.header')
    subject_el = soup.select_one('.subject')
    content_el = soup.select_one('.content')
    receivers_el = soup.select_one('.receivers-section')

    doc = Document()
    _apply_default_font(doc)
    _set_document_page(doc)

    # Header — 11pt, RTL/right-aligned, bottom border
    if header_el is not None:
        header_text = header_el.get_text('\n', strip=True)
        _add_styled_paragraph(
            doc,
            header_text,
            size_pt=11,
            align=WD_ALIGN_PARAGRAPH.RIGHT,
            before_pt=0,
            after_pt=12,
            border_bottom=True,
        )

    # Subject — matches .subject { font-weight:bold; font-size:15pt }
    if subject_el is not None:
        _add_styled_paragraph(
            doc,
            subject_el.get_text(' ', strip=True),
            size_pt=15,
            bold=True,
            align=WD_ALIGN_PARAGRAPH.RIGHT,
            before_pt=6,
            after_pt=14,
        )

    # Body — matches .content { text-align:justify; font-size:14pt }
    if content_el is not None:
        blocks = list(_iter_content_blocks(content_el))
        if blocks:
            for block in blocks:
                _add_styled_paragraph(
                    doc,
                    block,
                    size_pt=14,
                    align=WD_ALIGN_PARAGRAPH.JUSTIFY,
                    before_pt=0,
                    after_pt=10,
                )
        else:
            _add_styled_paragraph(
                doc,
                content_el.get_text('\n', strip=True),
                size_pt=14,
                align=WD_ALIGN_PARAGRAPH.JUSTIFY,
            )

    # Receivers — matches .receivers-section { font-size:13pt; border-top dashed }
    if receivers_el is not None:
        label_el = receivers_el.find(['strong', 'b'])
        label = label_el.get_text(strip=True) if label_el else 'گیرندگان:'
        items = [
            _element_text_with_breaks(li)
            for li in receivers_el.find_all('li')
        ]
        items = [i for i in items if i]
        if not items:
            # fallback whole section minus label
            full = _element_text_with_breaks(receivers_el)
            if label and full.startswith(label):
                full = full[len(label):].strip()
            items = [full] if full else []

        _add_styled_paragraph(
            doc,
            label,
            size_pt=13,
            bold=True,
            align=WD_ALIGN_PARAGRAPH.RIGHT,
            before_pt=18,
            after_pt=8,
            border_top_dashed=True,
        )
        for item in items:
            p = _add_styled_paragraph(
                doc,
                f"■ {item}",
                size_pt=13,
                align=WD_ALIGN_PARAGRAPH.RIGHT,
                before_pt=0,
                after_pt=6,
            )

    # Fallback if template classes were missing
    if not any([header_el, subject_el, content_el, receivers_el]):
        plain = soup.get_text('\n', strip=True)
        for line in plain.splitlines():
            if line.strip():
                _add_styled_paragraph(doc, line.strip(), size_pt=14)

    return doc


def step_2_convert_to_docx():
    print("\n" + "="*50)
    print("PHASE 2, STEP 2: CONVERTING HTML TO DOCX")
    print("="*50)

    os.makedirs(config.DOCX_DIR, exist_ok=True)
    files = [f for f in os.listdir(config.HTML_DIR) if f.endswith('.html')]
    total_files = len(files)
    print(f"Found {total_files} HTML files to convert.")

    success_count = 0
    fail_count = 0

    for index, filename in enumerate(files):
        html_path = os.path.abspath(os.path.join(config.HTML_DIR, filename))
        docx_filename = filename.replace('.html', '.docx')
        docx_path = os.path.abspath(os.path.join(config.DOCX_DIR, docx_filename))

        try:
            with open(html_path, 'r', encoding='utf-8-sig') as f:
                html_content = f.read()

            doc = _html_to_docx_document(html_content)
            doc.save(docx_path)
            success_count += 1
        except Exception as e:
            fail_count += 1
            print(f"Error converting {filename}: {e}")

        if (index + 1) % 50 == 0:
            print(
                f"Converted {index + 1} / {total_files} to DOCX "
                f"(ok={success_count}, fail={fail_count})..."
            )

    print(
        f"Step 2 Complete. Generated {success_count} DOCX files in '{config.DOCX_DIR}' "
        f"(failed={fail_count})."
    )


def step_2_convert_to_pdf():
    print("\n" + "=" * 50)
    print("PHASE 2, STEP 2: CONVERTING HTML TO PDF")
    print("=" * 50)

    import pathlib
    from playwright.sync_api import sync_playwright

    os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(config.BUNDLE_DIR, "pw-browsers")

    os.makedirs(config.PDF_DIR, exist_ok=True)
    files = [f for f in os.listdir(config.HTML_DIR) if f.endswith(".html")]
    total_files = len(files)
    print(f"Found {total_files} HTML files to convert.")

    success_count = 0
    fail_count = 0

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()

        for index, filename in enumerate(files):
            html_path = os.path.abspath(os.path.join(config.HTML_DIR, filename))
            pdf_filename = filename.replace(".html", ".pdf")
            pdf_path = os.path.abspath(os.path.join(config.PDF_DIR, pdf_filename))
            file_uri = pathlib.Path(html_path).as_uri()

            try:
                page.goto(file_uri)
                page.pdf(path=pdf_path, format="A4", print_background=True)
                success_count += 1
            except Exception as e:
                fail_count += 1
                print(f"Error converting {filename}: {e}")

            if (index + 1) % 50 == 0:
                print(
                    f"Converted {index + 1} / {total_files} to PDF "
                    f"(ok={success_count}, fail={fail_count})..."
                )

        browser.close()

    print(
        f"Step 2 Complete. Generated {success_count} PDF files in '{config.PDF_DIR}' "
        f"(failed={fail_count})."
    )


def step_3_insert_to_rahkaran(content_format: str = "docx"):
    meta = get_content_format_meta(content_format)
    ext = meta["ext"]
    ext_dot = meta["ext_dot"]
    content_type = meta["content_type"]
    output_dir = meta["output_dir"]
    label = meta["label"]

    print("\n" + "=" * 50)
    print(f"PHASE 2, STEP 3: INSERTING {label} FILES INTO RAHKARAN")
    print("=" * 50)

    try:
        print("Building Mapping Dictionary (by registration number)...")
        engine_rahkaran = get_sqlalchemy_engine(config.RAHKARAN_DB)
        mapping_query = f"""
            SELECT
                M.Ican_EntityCode,
                M.Rahkaran_LetterID,
                L.RegistrationNumber
            FROM master.dbo.Migration_IcanLetter_RahkaranLetter_Map M
            INNER JOIN [{config.RAHKARAN_DB}].ECM.Letter L
                ON L.LetterID = M.Rahkaran_LetterID
        """
        map_df = pd.read_sql(mapping_query, engine_rahkaran)

        engine_ican = get_sqlalchemy_engine(config.ICAN_DB)
        ican_df = pd.read_sql(
            f"SELECT EntityCode, EntityNumber FROM {config.ICAN_DB}.dbo.Entity_public_letter",
            engine_ican,
        )
        merged_df = pd.merge(
            map_df, ican_df, left_on="Ican_EntityCode", right_on="EntityCode", how="inner"
        )

        lookup_dict = {}
        for _, row in merged_df.iterrows():
            reg_no = row["RegistrationNumber"]
            if pd.notna(reg_no) and str(reg_no).strip():
                display_number = str(reg_no).strip()
            else:
                display_number = str(row["EntityNumber"])

            safe_name = _safe_letter_filename(display_number)
            lookup_dict[f"letter_{safe_name}.{ext}"] = {
                "LetterID": row["Rahkaran_LetterID"]
            }

        print("Fetching TableIdGen Seeds...")
        conn_rahkaran = get_rahkaran_conn()
        cursor = conn_rahkaran.cursor()

        cursor.execute(
            f"SELECT LastId FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.File'"
        )
        row_file = cursor.fetchone()
        last_file_id = int(row_file[0]) if row_file and row_file[0] is not None else 0

        cursor.execute(
            f"SELECT LastId FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.LetterContent'"
        )
        row_content = cursor.fetchone()
        last_content_id = int(row_content[0]) if row_content and row_content[0] is not None else 0

        print(f"Starting Database Upserts from '{output_dir}' ({label})...")
        files = [f for f in os.listdir(output_dir) if f.endswith(f".{ext}")]
        success_count = 0
        updated_count = 0

        for filename in files:
            if filename not in lookup_dict:
                continue

            letter_id = lookup_dict[filename]["LetterID"]
            filepath = os.path.join(output_dir, filename)

            with open(filepath, "rb") as f:
                file_bytes = f.read()

            file_size = len(file_bytes)
            file_hash_bytes = hashlib.sha256(file_bytes).digest()
            unique_id = str(uuid.uuid4()).upper()
            allocated_new_ids = False
            existing = None

            try:
                cursor.execute(
                    f"""
                    SELECT TOP 1 LetterContentID, ContentGuid
                    FROM [{config.RAHKARAN_DB}].ECM.LetterContent
                    WHERE LetterRef = ?
                    ORDER BY LetterContentID
                    """,
                    (letter_id,),
                )
                existing = cursor.fetchone()

                if existing:
                    content_guid = existing[1]
                    cursor.execute(
                        f"""
                        UPDATE [{config.RAHKARAN_DB}].ecm.[File]
                        SET Name = ?, Content = ?, ContentType = ?,
                            Size = ?, ContentHash = ?, LastModifier = ?,
                            LastModificationDate = GETDATE(), Ext = ?
                        WHERE UniqueId = ?
                        """,
                        (
                            filename,
                            pyodbc.Binary(file_bytes),
                            content_type,
                            file_size,
                            pyodbc.Binary(file_hash_bytes),
                            1,
                            ext,
                            content_guid,
                        ),
                    )

                    if cursor.rowcount == 0:
                        last_file_id += 1
                        allocated_new_ids = True
                        cursor.execute(
                            f"""
                            INSERT INTO [{config.RAHKARAN_DB}].ecm.[File]
                            (FileID, Name, Content, UniqueId, ReferenceCount, ContentType, Size,
                             ContentHash, Creator, CreationDate, LastModifier, LastModificationDate, Ext)
                            VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, GETDATE(), ?, GETDATE(), ?)
                            """,
                            (
                                last_file_id,
                                filename,
                                pyodbc.Binary(file_bytes),
                                content_guid,
                                content_type,
                                file_size,
                                pyodbc.Binary(file_hash_bytes),
                                1,
                                1,
                                ext,
                            ),
                        )

                    cursor.execute(
                        f"""
                        UPDATE [{config.RAHKARAN_DB}].ECM.LetterContent
                        SET Name = ?, Extention = ?, ContentSize = ?,
                            LastModifier = ?, LastModificationDate = GETDATE()
                        WHERE LetterContentID = ?
                        """,
                        (filename, ext_dot, file_size, 1, existing[0]),
                    )
                    cursor.execute(
                        f"UPDATE [{config.RAHKARAN_DB}].ECM.letter SET HasContent = 1 WHERE LetterID = ?",
                        (letter_id,),
                    )
                    conn_rahkaran.commit()
                    updated_count += 1
                else:
                    last_file_id += 1
                    last_content_id += 1
                    allocated_new_ids = True

                    cursor.execute(
                        f"""
                        INSERT INTO [{config.RAHKARAN_DB}].ecm.[File]
                        (FileID, Name, Content, UniqueId, ReferenceCount, ContentType, Size,
                         ContentHash, Creator, CreationDate, LastModifier, LastModificationDate, Ext)
                        VALUES (?, ?, ?, CAST(? AS UNIQUEIDENTIFIER), 1, ?, ?, ?, ?, GETDATE(), ?, GETDATE(), ?)
                        """,
                        (
                            last_file_id,
                            filename,
                            pyodbc.Binary(file_bytes),
                            unique_id,
                            content_type,
                            file_size,
                            pyodbc.Binary(file_hash_bytes),
                            1,
                            1,
                            ext,
                        ),
                    )

                    cursor.execute(
                        f"""
                        INSERT INTO [{config.RAHKARAN_DB}].ECM.LetterContent
                        (LetterContentID, LetterRef, ContentGuid, Name, Extention, Type, [Order],
                         Creator, CreationDate, LastModifier, LastModificationDate, ContentSize)
                        VALUES (?, ?, CAST(? AS UNIQUEIDENTIFIER), ?, ?, 2, 1, ?, GETDATE(), ?, GETDATE(), ?)
                        """,
                        (last_content_id, letter_id, unique_id, filename, ext_dot, 1, 1, file_size),
                    )

                    cursor.execute(
                        f"UPDATE [{config.RAHKARAN_DB}].ECM.letter SET HasContent = 1 WHERE LetterID = ?",
                        (letter_id,),
                    )
                    conn_rahkaran.commit()
                    success_count += 1

                if (updated_count + success_count) % 100 == 0:
                    print(
                        f"Processed {updated_count + success_count} files "
                        f"(inserted={success_count}, updated={updated_count})..."
                    )

            except Exception as insert_err:
                print(f"Failed to upsert {filename}: {insert_err}")
                conn_rahkaran.rollback()
                if allocated_new_ids:
                    last_file_id = max(last_file_id - 1, 0)
                    if existing is None:
                        last_content_id = max(last_content_id - 1, 0)
                continue

        print("Updating TableIdGen...")

        update_file_query = f"""
            IF EXISTS (SELECT 1 FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.File')
                UPDATE [{config.RAHKARAN_DB}].SYS3.TableIdGen SET LastId = ? WHERE TableName = 'ECM.File'
            ELSE
                INSERT INTO [{config.RAHKARAN_DB}].SYS3.TableIdGen (TableName, LastId) VALUES ('ECM.File', ?)
        """
        cursor.execute(update_file_query, (last_file_id, last_file_id))

        update_content_query = f"""
            IF EXISTS (SELECT 1 FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.LetterContent')
                UPDATE [{config.RAHKARAN_DB}].SYS3.TableIdGen SET LastId = ? WHERE TableName = 'ECM.LetterContent'
            ELSE
                INSERT INTO [{config.RAHKARAN_DB}].SYS3.TableIdGen (TableName, LastId) VALUES ('ECM.LetterContent', ?)
        """
        cursor.execute(update_content_query, (last_content_id, last_content_id))

        conn_rahkaran.commit()
        print(f"Step 3 Complete. Inserted {success_count}, updated {updated_count} ({label}).")

    except Exception as e:
        print(f"Step 3 Failed: {e}")
    finally:
        if "conn_rahkaran" in locals() and conn_rahkaran:
            conn_rahkaran.close()


def run_all_content_migrations(content_format: str = "docx"):
    fmt = normalize_content_format(content_format)
    step_1_extract_html()
    if fmt == "pdf":
        step_2_convert_to_pdf()
    else:
        step_2_convert_to_docx()
    step_3_insert_to_rahkaran(fmt)
