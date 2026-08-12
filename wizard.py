import os
import sys
import pyodbc

# Import our custom modules
import config
import main

def get_app_dir():
    """Determines the directory where the .exe (or script) is physically located."""
    if getattr(sys, 'frozen', False):
        # Running as a compiled PyInstaller executable
        return os.path.dirname(sys.executable)
    else:
        # Running as a standard Python script
        return os.path.dirname(os.path.abspath(__file__))

def load_settings(filepath):
    """Reads key=value pairs from a text file."""
    settings = {}
    if os.path.exists(filepath):
        with open(filepath, 'r', encoding='utf-8-sig') as f:
            for line in f:
                line = line.strip()
                # Ignore empty lines and comments
                if line and not line.startswith('#') and '=' in line:
                    key, val = line.split('=', 1)
                    settings[key.strip().upper()] = val.strip()
    return settings

def create_template_settings(filepath):
    """Generates a blank settings.txt file for the user to fill out."""
    template = (
        "# Database Migration Settings\n"
        "SERVER=127.0.0.1\n"
        "USERNAME=sa\n"
        "PASSWORD=\n"
        "ICAN_DB=ican\n"
        "RAHKARAN_DB=madani_sg3\n"
        "# Optional: pdf or docx (interactive prompt can override)\n"
        "#CONTENT_FORMAT=docx\n"
    )
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(template)

def test_connection(server, user, password, database):
    """Tests if a SQL connection can be established using ODBC Driver 17."""
    connection_string = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={server};"
        f"DATABASE={database};"
        f"UID={user};"
        f"PWD={password};"
        f"TrustServerCertificate=yes;"
    )
    try:
        conn = pyodbc.connect(connection_string, timeout=5)
        conn.close()
        return True
    except Exception as e:
        print(f"\n❌ Failed to connect to {database}.")
        print(f"Error Details: {e}")
        return False

def run_wizard():
    print("==================================================")
    print("ICAN TO RAHKARAN MIGRATION - SETUP")
    print("==================================================")

    # 1. Locate or create the settings file
    app_dir = get_app_dir()
    settings_file = os.path.join(app_dir, 'settings.txt')

    if not os.path.exists(settings_file):
        print(f"⚠️  No settings.txt found in the application directory.")
        create_template_settings(settings_file)
        print(f"📄 A template 'settings.txt' has been created here:\n   {settings_file}")
        print("\nPlease open it, fill in your database credentials, and restart the application.")
        input("\nPress Enter to exit...")
        sys.exit(0)

    # 2. Load settings from the file
    print(f"📂 Loading configuration from settings.txt...")
    settings = load_settings(settings_file)

    server_ip = settings.get('SERVER', '')
    username = settings.get('USERNAME', '')
    password = settings.get('PASSWORD', '')
    ican_db = settings.get('ICAN_DB', '')
    rahkaran_db = settings.get('RAHKARAN_DB', '')

    # Validate that the file isn't empty
    if not all([server_ip, username, password, ican_db, rahkaran_db]):
        print("❌ ERROR: Missing credentials in settings.txt.")
        print("Please make sure SERVER, USERNAME, PASSWORD, ICAN_DB, and RAHKARAN_DB are all filled out.")
        input("\nPress Enter to exit...")
        sys.exit(1)

    # 3. Test connections
    print(f"\n⏳ Testing connection to {ican_db} at {server_ip}...")
    if not test_connection(server_ip, username, password, ican_db):
        input("\nPress Enter to exit and fix your settings.txt...")
        sys.exit(1)
    print(f"✅ Successfully connected to {ican_db}!")

    print(f"⏳ Testing connection to {rahkaran_db} at {server_ip}...")
    if not test_connection(server_ip, username, password, rahkaran_db):
        input("\nPress Enter to exit and fix your settings.txt...")
        sys.exit(1)
    print(f"✅ Successfully connected to {rahkaran_db}!\n")

    # 4. Inject live settings into the config module in memory
    config.DB_SERVER = server_ip
    config.DB_USER = username
    config.DB_PASSWORD = password
    config.ICAN_DB = ican_db
    config.RAHKARAN_DB = rahkaran_db
    
    print("🚀 Launching Main Migration Pipeline...")
    
    # 5. Call the main pipeline execution
    try:
        main.run_sql_phase()
        main.run_content_phase()
        print("\n🌟 MIGRATION COMPLETE!")
        
    except Exception as e:
        print(f"\n❌ FATAL ERROR IN PIPELINE: {e}")
    finally:
        input("\nPress Enter to close this window...")

if __name__ == "__main__":
    run_wizard()