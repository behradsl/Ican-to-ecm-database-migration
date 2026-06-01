import os
import glob
import sys

import config
from db_utils import get_rahkaran_conn, execute_sql_file
from content_migration.migrator import run_all_content_migrations

def run_sql_phase():
    print("="*50)
    print("PHASE 1: EXECUTING SQL MIGRATION SCRIPTS")
    print("="*50)
    
    # Grab all .sql files from the sql_scripts directory and sort them alphabetically/numerically
    sql_files = sorted(glob.glob(os.path.join(config.SQL_SCRIPTS_DIR, "*.sql")))
    
    if not sql_files:
        print(f"⚠️ No SQL files found in {config.SQL_SCRIPTS_DIR}. Skipping Phase 1.")
        return

    # Use a single connection for the SQL files. 
    # (Since your scripts contain cross-database logic, running them via the Rahkaran connection context is standard).
    conn = get_rahkaran_conn()
    
    try:
        for file_path in sql_files:
            file_name = os.path.basename(file_path)
            print(f"Running: {file_name} ...")
            
            # This function uses the safe batch-splitting logic we wrote in db_utils
            execute_sql_file(conn, file_path)
            
        print("✅ Phase 1 (SQL Scripts) Complete!")
        
    except Exception as e:
        print("\n❌ CRITICAL ERROR IN SQL PHASE. Halting migration.")
        print(f"Details: {e}")
        sys.exit(1) # Stop the script entirely so we don't insert files into broken DB states
        
    finally:
        conn.close()

if __name__ == "__main__":
    print("🚀 STARTING FULL ICAN -> RAHKARAN MIGRATION PIPELINE")
    
    # 1. Run the relational data migration (Users, Roles, Letters, Mappings)
    run_sql_phase()
    
    # 2. Run the physical file extraction, PDF conversion, and binary insertion
    run_all_content_migrations()
    
    print("\n" + "="*50)
    print("🌟 ENTIRE MIGRATION PIPELINE FINISHED SUCCESSFULLY! 🌟")
    print("="*50)