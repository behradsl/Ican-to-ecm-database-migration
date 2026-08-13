import os
import sys
import pyodbc

import re

# Import configuration and database utilities
import config
from db_utils import get_rahkaran_conn

def prompt_user(action_desc):
    """Interactive prompt to control the flow of the pipeline."""
    while True:
        choice = input(f"\n---> Next Action: {action_desc}\nPress ENTER to execute, 's' to skip, or 'q' to quit: ").strip().lower()
        if choice == '':
            return True
        elif choice == 's':
            print(f"⏭️ Skipped: {action_desc}")
            return False
        elif choice == 'q':
            print("🛑 Exiting pipeline.")
            sys.exit(0)
        else:
            print("Invalid input. Press ENTER, 's', or 'q'.")


def prompt_content_format():
    """
    Ask user to choose letter content format: PDF or DOCX.
    Optional default from settings.txt CONTENT_FORMAT=pdf|docx.
    """
    default = (getattr(config, "CONTENT_FORMAT", "") or "").strip().lower()
    default_hint = f" [default={default}]" if default in ("pdf", "docx") else ""

    while True:
        choice = input(
            f"\n---> Letter content format{default_hint}\n"
            "Enter 1 for PDF, 2 for DOCX"
            + (", ENTER for default" if default in ("pdf", "docx") else "")
            + ", or 'q' to quit: "
        ).strip().lower()

        if choice == "q":
            print("🛑 Exiting pipeline.")
            sys.exit(0)
        if choice == "" and default in ("pdf", "docx"):
            print(f"Using content format from settings: {default.upper()}")
            return default
        if choice in ("1", "pdf"):
            print("Selected content format: PDF")
            return "pdf"
        if choice in ("2", "docx", "word"):
            print("Selected content format: DOCX")
            return "docx"
        print(
            "Invalid input. Enter 1 (PDF), 2 (DOCX)"
            + (", ENTER for default" if default in ("pdf", "docx") else "")
            + ", or q."
        )


def run_content_phase():
    """Phase 2: HTML extract -> convert (pdf|docx) -> insert chosen format."""
    print("\n" + "=" * 50)
    print("PHASE 2: CONTENT MIGRATION")
    print("=" * 50)

    if prompt_user("Extract HTML files from ICAN Database"):
        from content_migration.migrator import step_1_extract_html
        step_1_extract_html()

    content_format = prompt_content_format()

    if content_format == "pdf":
        if prompt_user("Convert HTML files to PDF via Playwright"):
            from content_migration.migrator import step_2_convert_to_pdf
            step_2_convert_to_pdf()
    else:
        if prompt_user("Convert HTML files to DOCX (Word)"):
            from content_migration.migrator import step_2_convert_to_docx
            step_2_convert_to_docx()

    if prompt_user(f"Insert {content_format.upper()} binaries into Rahkaran Database"):
        from content_migration.migrator import step_3_insert_to_rahkaran
        step_3_insert_to_rahkaran(content_format)

    if prompt_user("Insert letter/import/export attachments into Rahkaran"):
        from content_migration.migrator import step_4_insert_attachments
        step_4_insert_attachments()


def execute_sql_script(filename):
    """Reads a SQL file, injects database names, splits by GO, and executes it."""
    filepath = os.path.join(config.SQL_SCRIPTS_DIR, filename)

    if not os.path.exists(filepath):
        print(f"❌ Error: Could not find '{filename}' in '{config.SQL_SCRIPTS_DIR}'")
        sys.exit(1)

    print(f"Running: {filename} ...")

    with open(filepath, 'r', encoding='utf-8-sig') as f:
        sql_content = f.read()

    # Inject dynamic database names from config
    sql_content = sql_content.replace('{{ICAN_DB}}', config.ICAN_DB)
    sql_content = sql_content.replace('{{RAHKARAN_DB}}', config.RAHKARAN_DB)

    conn = get_rahkaran_conn()
    conn.autocommit = True
    cursor = conn.cursor()

    # BETTER SPLITTING: Handles different Windows/Mac line endings and spaces safely
    batches = re.split(r'(?i)^\s*GO\s*$', sql_content, flags=re.MULTILINE)

    try:
        for batch in batches:
            if batch.strip():
                # THE FIX: Force SQL Server to stop spamming "1 row affected" so Pyodbc sees the actual errors
                safe_batch = "SET NOCOUNT ON;\n" + batch
                cursor.execute(safe_batch)

                # THE FIX: Force Pyodbc to consume all data to uncover hidden THROW commands
                while cursor.nextset():
                    pass

        print(f"✅ Successfully executed: {filename}")
    except Exception as e:
        print(f"❌ FAILED executing {filename}")
        print(f"Error Details: {e}")
        print(f"\n❌ CRITICAL ERROR IN SQL PHASE. Halting migration.")
        sys.exit(1)
    finally:
        conn.close()

def run_sql_phase():
    """Orchestrates Phase 1: The SQL Data Migration"""
    print("\n" + "="*50)
    print("PHASE 1: EXECUTING SQL MIGRATION SCRIPTS")
    print("="*50)

    # THE NEW SEQUENCE: Note that script 5 is intentionally listed twice!
    sql_sequence = [
        "1_userToParty.sql",
        "2_RoleToPost.sql",
        "3_departmentToParty(company).sql",
        "4_organizationRoleToParty.sql",
        "5_adMissingCorespondants.sql",
        "6_updateIdMappings.sql",
        "7_entity_public_letter_To ECM_Letter.sql",
        "8_Extract_Letter_Receivers.sql",
        "9_Resolve_Missing_Parties.sql",
        "5_adMissingCorespondants.sql",   # <--- RE-RUNNING STEP 5 HERE
        "10_Insert_Letter_Receivers.sql"
    ]

    for script in sql_sequence:
        if prompt_user(f"Run SQL Script '{script}'"):
            execute_sql_script(script)

# If running this script directly instead of through wizard.py
if __name__ == "__main__":
    print("🚀 STARTING INTERACTIVE ICAN -> RAHKARAN MIGRATION PIPELINE")
    run_sql_phase()
    run_content_phase()
    print("\n🌟 MIGRATION COMPLETE!")
