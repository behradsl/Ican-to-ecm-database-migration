import os
import sys
import pyodbc

# ======================================================================
# OFFLINE BROWSER CONFIGURATION
# Determine the base path whether running as script or bundled executable
# ======================================================================
if getattr(sys, 'frozen', False):
    # Running as a compiled PyInstaller executable
    base_path = sys._MEIPASS
else:
    # Running as a normal Python script
    base_path = os.path.abspath(os.path.dirname(__file__))

# Force Playwright to use the offline bundled browser directory BEFORE any imports
os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(base_path, "pw-browsers")
os.environ["PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"] = "1" # Prevent accidental downloads

# Now import the rest of your app
import config
from sqlalchemy import create_engine

# We must set this before importing playwright so it knows where to find the bundled browser
os.environ["PLAYWRIGHT_BROWSERS_PATH"] = os.path.join(os.getcwd(), "pw-browsers")

def test_sql_connection(db_name, server, user, password):
    print(f"\n⏳ Testing connection to {db_name}...")
    conn_str = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={server};DATABASE={db_name};UID={user};PWD={password}"
    try:
        conn = pyodbc.connect(conn_str, timeout=5)
        conn.close()
        print(f"✅ Successfully connected to {db_name}!")
        
        # Return the SQLAlchemy URL format required by pandas
        return f"mssql+pyodbc://{user}:{password}@{server}/{db_name}?driver=ODBC+Driver+17+for+SQL+Server"
    except Exception as e:
        print(f"❌ Failed to connect to {db_name}. Please check your credentials.")
        print(f"Error: {e}")
        return None

def main():
    print("="*50)
    print("ICAN TO RAHKARAN MIGRATION - SETUP WIZARD")
    print("="*50)

    server = input("Enter SQL Server IP/Instance Name (e.g., 192.168.1.100): ").strip()
    user = input("Enter SQL Username (e.g., sa): ").strip()
    password = input("Enter SQL Password: ").strip()
    
    ican_db = input("Enter ICAN Database Name: ").strip()
    rahkaran_db = input("Enter Rahkaran Database Name (e.g., MadaniSG): ").strip()

    # Test Connections
    url_ican = test_sql_connection(ican_db, server, user, password)
    if not url_ican:
        input("\nPress ENTER to exit...")
        sys.exit(1)

    url_rahkaran = test_sql_connection(rahkaran_db, server, user, password)
    if not url_rahkaran:
        input("\nPress ENTER to exit...")
        sys.exit(1)

    print("\n✅ All connections verified. Generating configuration...")

    # Dynamically inject the credentials into your existing config module
    import config
    config.URL_ICAN = url_ican
    config.URL_RAHKARAN = url_rahkaran
    config.ICAN_DB = ican_db
    config.RAHKARAN_DB = rahkaran_db
    
    # Ensure output directories exist
    os.makedirs(config.HTML_DIR, exist_ok=True)
    os.makedirs(config.PDF_DIR, exist_ok=True)

    print("\n🚀 Launching Main Migration Pipeline...\n")
    
    # Import and run your main orchestrator
    import main as migration_pipeline
    
    # Run the SQL phase
    migration_pipeline.run_sql_phase()
    
    # Run the Content Phase
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