import os
import sys
import pyodbc
import getpass
import time

# ======================================================================
# PATH CONFIGURATION
# ======================================================================
if getattr(sys, 'frozen', False):
    base_path = sys._MEIPASS
else:
    base_path = os.path.abspath(os.path.dirname(__file__))

os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(base_path, "pw-browsers")
os.environ["PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"] = "1"

# ======================================================================
# TIME-LOCKED SECURITY CONFIGURATION
# ======================================================================
MASTER_PASSWORD = "%%GENERATED_PASSWORD%%" 
EXPIRATION_TIMESTAMP = %%EXPIRATION_TIMESTAMP%% 

def verify_security():
    """Enforces the 1-hour expiration and password protection."""
    print("="*50)
    print("⏳ SECURE ACCESS REQUIRED")
    print("="*50)
    
    # 1. Time Expiration Check
    current_time = time.time()
    if current_time > EXPIRATION_TIMESTAMP:
        print("\n❌ SECURITY ERROR: This executable has expired.")
        print("The 1-hour validity window has closed. Please request a new build.")
        input("Press ENTER to exit...")
        sys.exit(1)
        
    # Calculate and display remaining time
    remaining_minutes = int((EXPIRATION_TIMESTAMP - current_time) / 60)
    print(f"⏱️  Time remaining on this executable: {remaining_minutes} minutes.\n")

    # 2. Password Protection
    entered_password = getpass.getpass("Enter Execution Password: ")
    
    if entered_password != MASTER_PASSWORD:
        print("\n❌ ACCESS DENIED: Incorrect password.")
        input("Press ENTER to exit...")
        sys.exit(1)

    print("✅ Access Granted.\n")

# ======================================================================
# DATABASE LOGIC & ORCHESTRATION
# ======================================================================
def test_sql_connection(db_name, server, user, password):
    print(f"⏳ Testing connection to {db_name}...")
    conn_str = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={server};DATABASE={db_name};UID={user};PWD={password}"
    try:
        conn = pyodbc.connect(conn_str, timeout=5)
        conn.close()
        print(f"✅ Successfully connected to {db_name}!")
        return f"mssql+pyodbc://{user}:{password}@{server}/{db_name}?driver=ODBC+Driver+17+for+SQL+Server"
    except Exception as e:
        print(f"❌ Failed to connect to {db_name}. Please check your credentials.")
        return None

def main():
    # Enforce time limit and password immediately
    verify_security()

    print("="*50)
    print("ICAN TO RAHKARAN MIGRATION - SETUP WIZARD")
    print("="*50)

    server = input("Enter SQL Server IP/Instance Name (e.g., 192.168.1.100): ").strip()
    user = input("Enter SQL Username (e.g., sa): ").strip()
    password = input("Enter SQL Password: ").strip()
    
    ican_db = input("Enter ICAN Database Name: ").strip()
    rahkaran_db = input("Enter Rahkaran Database Name (e.g., MadaniSG): ").strip()

    url_ican = test_sql_connection(ican_db, server, user, password)
    if not url_ican:
        input("\nPress ENTER to exit...")
        sys.exit(1)

    url_rahkaran = test_sql_connection(rahkaran_db, server, user, password)
    if not url_rahkaran:
        input("\nPress ENTER to exit...")
        sys.exit(1)

    print("\n✅ All connections verified. Generating configuration...")

    import config
    config.URL_ICAN = url_ican
    config.URL_RAHKARAN = url_rahkaran
    config.ICAN_DB = ican_db
    config.RAHKARAN_DB = rahkaran_db
    
    os.makedirs(config.HTML_DIR, exist_ok=True)
    os.makedirs(config.PDF_DIR, exist_ok=True)

    print("\n🚀 Launching Main Migration Pipeline...\n")
    import main as migration_pipeline
    
    migration_pipeline.run_sql_phase()
    
    print("\n" + "="*50)
    print("PHASE 2: CONTENT MIGRATION")
    print("="*50)
    
    if migration_pipeline.prompt_user("Extract HTML files from ICAN Database"):
        from content_migration.migrator import step_1_extract_html
        step_1_extract_html()

    if migration_pipeline.prompt_user("Convert HTML files to PDF via Playwright"):
        from content_migration.migrator import step_2_convert_to_pdf
        step_2_convert_to_pdf()

    if migration_pipeline.prompt_user("Insert PDF binaries into Rahkaran Database"):
        from content_migration.migrator import step_3_insert_to_rahkaran
        step_3_insert_to_rahkaran()

    input("\n🌟 MIGRATION COMPLETE! Press ENTER to exit.")

if __name__ == "__main__":
    main()