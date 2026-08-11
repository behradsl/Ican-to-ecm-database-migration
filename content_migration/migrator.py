import os
import pyodbc
import hashlib
import uuid
import re
import pandas as pd
import jdatetime
import pathlib
from playwright.sync_api import sync_playwright

# Import our centralized config and db utilities
import config
from db_utils import get_ican_conn, get_rahkaran_conn, get_sqlalchemy_engine

import xml.etree.ElementTree as ET

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
                
                # ADDED: Selected the 'Receivers' XML column
                query = f"""
                    SELECT EntityNumber, Subject, CreationDate, Text, Receivers 
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
                    entity_number = str(row.get('EntityNumber', 'Unknown'))
                    subject = str(row.get('Subject', 'بدون موضوع'))
                    
                    raw_date = row.get('CreationDate', None)
                    shamsi_date_str = ''
                    if pd.notna(raw_date):
                        try:
                            gregorian_date = raw_date.date() if hasattr(raw_date, 'date') else pd.to_datetime(str(raw_date)).date()
                            jalali_date = jdatetime.date.fromgregorian(date=gregorian_date)
                            shamsi_date_str = jalali_date.strftime("%Y/%m/%d")
                        except Exception:
                            shamsi_date_str = str(raw_date).split(' ')[0]
                    
                    raw_text = row.get('Text', '')
                    body_html = str(raw_text) if pd.notna(raw_text) else ''

                    # =========================================================
                    # NEW: Parse XML Receivers and extract Captions
                    # =========================================================
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
                            print(f"⚠️ XML Parse Warning for letter {entity_number}: {xml_err}")
                            pass # If XML is corrupted, we simply skip adding the receivers section
                    # =========================================================

                    safe_filename = re.sub(r'[\\/*?:"<>|]', '-', entity_number)
                    final_html = html_template.format(
                        subject=subject, 
                        entity_number=entity_number, 
                        date=shamsi_date_str, 
                        body_html=body_html,
                        receivers_html=receivers_html  # Inject the generated receivers
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
def step_2_convert_to_pdf():
    print("\n" + "="*50)
    print("PHASE 2, STEP 2: CONVERTING HTML TO PDF")
    print("="*50)

    os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(config.BUNDLE_DIR, 'pw-browsers')
    
    files = [f for f in os.listdir(config.HTML_DIR) if f.endswith('.html')]
    total_files = len(files)
    print(f"Found {total_files} HTML files to convert.")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()

        for index, filename in enumerate(files):
            html_path = os.path.abspath(os.path.join(config.HTML_DIR, filename))
            pdf_filename = filename.replace('.html', '.pdf')
            pdf_path = os.path.abspath(os.path.join(config.PDF_DIR, pdf_filename))

            file_uri = pathlib.Path(html_path).as_uri()

            try:
                page.goto(file_uri)
                page.pdf(path=pdf_path, format="A4", print_background=True)
            except Exception as e:
                print(f"❌ Error converting {filename}: {e}")

            if (index + 1) % 50 == 0:
                print(f"Converted {index + 1} / {total_files} to PDF...")

        browser.close()
        print(f"🎉 Step 2 Complete. All PDFs generated in '{config.PDF_DIR}'.")

def step_3_insert_to_rahkaran():
    print("\n" + "="*50)
    print("PHASE 2, STEP 3: INSERTING FILES INTO RAHKARAN")
    print("="*50)
    
    try:
        print("Building Mapping Dictionary...")
        engine_ican = get_sqlalchemy_engine(config.ICAN_DB)
        ican_df = pd.read_sql(f"SELECT EntityCode, EntityNumber FROM {config.ICAN_DB}.dbo.Entity_public_letter", engine_ican)

        engine_rahkaran = get_sqlalchemy_engine(config.RAHKARAN_DB)
        mapping_query = "SELECT Ican_EntityCode, Rahkaran_LetterID FROM master.dbo.Migration_IcanLetter_RahkaranLetter_Map"
        map_df = pd.read_sql(mapping_query, engine_rahkaran)

        merged_df = pd.merge(ican_df, map_df, left_on='EntityCode', right_on='Ican_EntityCode', how='inner')
        
        lookup_dict = {}
        for index, row in merged_df.iterrows():
            entity_number = str(row['EntityNumber'])
            safe_name = re.sub(r'[\\/*?:"<>|]', '-', entity_number)
            lookup_dict[f"letter_{safe_name}.pdf"] = {
                'LetterID': row['Rahkaran_LetterID']
            }
            
        print("Fetching TableIdGen Seeds...")
        conn_rahkaran = get_rahkaran_conn()
        cursor = conn_rahkaran.cursor()
        
        # FIX: Gracefully handle NULL or missing ECM.File seed
        cursor.execute(f"SELECT LastId FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.File'")
        row_file = cursor.fetchone()
        last_file_id = int(row_file[0]) if row_file and row_file[0] is not None else 0
        
        # FIX: Gracefully handle NULL or missing ECM.LetterContent seed
        cursor.execute(f"SELECT LastId FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.LetterContent'")
        row_content = cursor.fetchone()
        last_content_id = int(row_content[0]) if row_content and row_content[0] is not None else 0
        
        print("Starting Database Insertions...")
        files = [f for f in os.listdir(config.PDF_DIR) if f.endswith('.pdf')]
        success_count = 0

        for index, filename in enumerate(files):
            if filename not in lookup_dict:
                continue
                
            letter_id = lookup_dict[filename]['LetterID']
            filepath = os.path.join(config.PDF_DIR, filename)
            
            with open(filepath, 'rb') as f:
                file_bytes = f.read()
                
            file_size = len(file_bytes)
            file_hash_bytes = hashlib.sha256(file_bytes).digest() 
            unique_id = str(uuid.uuid4()).upper()
            
            try:
                last_file_id += 1
                last_content_id += 1
                
                # Insert File
                insert_file_query = f"""
                    INSERT INTO [{config.RAHKARAN_DB}].ecm.[File] 
                    (FileID, Name, Content, UniqueId, ReferenceCount, ContentType, Size, ContentHash, Creator, CreationDate, LastModifier, LastModificationDate, Ext)
                    VALUES (?, ?, ?, CAST(? AS UNIQUEIDENTIFIER), 1, 'application/pdf', ?, ?, ?, GETDATE(), ?, GETDATE(), 'pdf')
                """
                cursor.execute(insert_file_query, (
                    last_file_id, filename, pyodbc.Binary(file_bytes), unique_id, file_size, 
                    pyodbc.Binary(file_hash_bytes), 1, 1
                ))
                
                # Insert Content Link
                insert_content_query = f"""
                    INSERT INTO [{config.RAHKARAN_DB}].ECM.LetterContent
                    (LetterContentID, LetterRef, ContentGuid, Name, Extention, Type, [Order], Creator, CreationDate, LastModifier, LastModificationDate, ContentSize)
                    VALUES (?, ?, CAST(? AS UNIQUEIDENTIFIER), ?, '.pdf', 2, 1, ?, GETDATE(), ?, GETDATE(), ?)
                """
                cursor.execute(insert_content_query, (
                    last_content_id, letter_id, unique_id, filename, 1, 1, file_size
                ))
                
                # Update Flag
                cursor.execute(f"UPDATE [{config.RAHKARAN_DB}].ECM.letter SET HasContent = 1 WHERE LetterID = ?", (letter_id,))
                
                conn_rahkaran.commit()
                success_count += 1
                
                if success_count % 100 == 0: print(f"Inserted {success_count} files...")
                
            except Exception as insert_err:
                print(f"❌ Failed to insert {filename}: {insert_err}")
                conn_rahkaran.rollback() 
                last_file_id -= 1
                last_content_id -= 1
                continue

        print("Updating TableIdGen...")
        
        # FIX: Use IF EXISTS for ECM.File so it creates the seed row if it was missing
        update_file_query = f"""
            IF EXISTS (SELECT 1 FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.File')
                UPDATE [{config.RAHKARAN_DB}].SYS3.TableIdGen SET LastId = ? WHERE TableName = 'ECM.File'
            ELSE
                INSERT INTO [{config.RAHKARAN_DB}].SYS3.TableIdGen (TableName, LastId) VALUES ('ECM.File', ?)
        """
        cursor.execute(update_file_query, (last_file_id, last_file_id))
        
        # FIX: Use IF EXISTS for ECM.LetterContent so it creates the seed row if it was missing
        update_content_query = f"""
            IF EXISTS (SELECT 1 FROM [{config.RAHKARAN_DB}].SYS3.TableIdGen WHERE TableName = 'ECM.LetterContent')
                UPDATE [{config.RAHKARAN_DB}].SYS3.TableIdGen SET LastId = ? WHERE TableName = 'ECM.LetterContent'
            ELSE
                INSERT INTO [{config.RAHKARAN_DB}].SYS3.TableIdGen (TableName, LastId) VALUES ('ECM.LetterContent', ?)
        """
        cursor.execute(update_content_query, (last_content_id, last_content_id))
        
        conn_rahkaran.commit()
        
        print(f"🎉 Step 3 Complete. Successfully migrated {success_count} files into Rahkaran.")

    except Exception as e:
        print(f"❌ Step 3 Failed: {e}")
    finally:
        if 'conn_rahkaran' in locals() and conn_rahkaran:
            conn_rahkaran.close()

def run_all_content_migrations():
    step_1_extract_html()
    step_2_convert_to_pdf()
    step_3_insert_to_rahkaran()