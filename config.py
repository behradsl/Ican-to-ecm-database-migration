import os
from urllib.parse import quote_plus

# ==========================================
# DATABASE SETTINGS
# ==========================================
SERVER = r'tcp:DESKTOP-A2JKATD,1433' 
ICAN_DB = 'ican'
RAHKARAN_DB = 'RahkaranSG'  # <--- Change this to your actual Rahkaran DB name

# System Defaults
ADMIN_USER_ID = 1

# ==========================================
# DIRECTORIES
# ==========================================
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

SQL_SCRIPTS_DIR = os.path.join(BASE_DIR, 'sql_scripts')
HTML_DIR = os.path.join(BASE_DIR, 'html_letters')
PDF_DIR = os.path.join(BASE_DIR, 'pdf_letters')

# Ensure output directories exist
os.makedirs(HTML_DIR, exist_ok=True)
os.makedirs(PDF_DIR, exist_ok=True)

# ==========================================
# CONNECTION STRINGS
# ==========================================
# Raw pyodbc strings (for fast inserts and script execution)
RAW_CONN_ICAN = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={SERVER};DATABASE={ICAN_DB};Trusted_Connection=yes;Encrypt=no;"
RAW_CONN_RAHKARAN = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={SERVER};DATABASE={RAHKARAN_DB};Trusted_Connection=yes;Encrypt=no;"

# URL Encoded strings for SQLAlchemy (for Pandas)
PARAMS_ICAN = quote_plus(RAW_CONN_ICAN)
PARAMS_RAHKARAN = quote_plus(RAW_CONN_RAHKARAN)

URL_ICAN = f"mssql+pyodbc:///?odbc_connect={PARAMS_ICAN}"
URL_RAHKARAN = f"mssql+pyodbc:///?odbc_connect={PARAMS_RAHKARAN}"