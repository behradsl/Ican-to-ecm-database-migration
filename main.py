import os
import glob
import sys

import config
from db_utils import get_rahkaran_conn, execute_sql_file
from content_migration.migrator import step_1_extract_html, step_2_convert_to_pdf, step_3_insert_to_rahkaran

def prompt_user(step_name):
    """Pauses execution and asks the user for permission to proceed, skip, or quit."""
    print(f"\n---> Next Action: {step_name}")
    user_input = input("Press ENTER to execute, 's' to skip, or 'q' to quit: ").strip().lower()
    
    if user_input == 'q':
        print("\n⏹️ Migration aborted by user.")
        sys.exit(0)
    elif user_input == 's':
        print(f"⏭️ Skipped: {step_name}")
        return False
    return True

def run_sql_phase():
    print("="*50)
    print("PHASE 1: EXECUTING SQL MIGRATION SCRIPTS")
    print("="*50)
    
    sql_files = sorted(glob.glob(os.path.join(config.SQL_SCRIPTS_DIR, "*.sql")))
    
    if not sql_files:
        print(f"⚠️ No SQL files found in {config.SQL_SCRIPTS_DIR}. Skipping Phase 1.")
        return

    conn = get_rahkaran_conn()
    
    try:
        for file_path in sql_files:
            file_name = os.path.basename(file_path)
            
            if prompt_user(f"Run SQL Script '{file_name}'"):
                print(f"Running: {file_name} ...")
                execute_sql_file(conn, file_path)
            
        print("\n✅ Phase 1 (SQL Scripts) Complete!")
        
    except Exception as e:
        print("\n❌ CRITICAL ERROR IN SQL PHASE. Halting migration.")
        print(f"Details: {e}")
        sys.exit(1)
        
    finally:
        conn.close()

if __name__ == "__main__":
    print("🚀 STARTING INTERACTIVE ICAN -> RAHKARAN MIGRATION PIPELINE")
    
    # 1. Run the relational data migration step-by-step
    run_sql_phase()
    
    # 2. Run the content migration step-by-step
    print("\n" + "="*50)
    print("PHASE 2: CONTENT MIGRATION")
    print("="*50)

    if prompt_user("Extract HTML files from ICAN Database"):
        step_1_extract_html()

    if prompt_user("Convert HTML files to PDF via Playwright"):
        step_2_convert_to_pdf()

    if prompt_user("Insert PDF binaries into Rahkaran Database"):
        step_3_insert_to_rahkaran()
    
    print("\n" + "="*50)
    print("🌟 ENTIRE MIGRATION PIPELINE FINISHED SUCCESSFULLY! 🌟")
    print("="*50)