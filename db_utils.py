import pyodbc
import re
import os
from sqlalchemy import create_engine
import config

def get_rahkaran_conn():
    """Returns a raw pyodbc connection to the Rahkaran DB."""
    return pyodbc.connect(config.RAW_CONN_RAHKARAN)

def get_ican_conn():
    """Returns a raw pyodbc connection to the ICAN DB."""
    return pyodbc.connect(config.RAW_CONN_ICAN)

def get_sqlalchemy_engine(db_url):
    """Returns a SQLAlchemy engine (used mostly by pandas)."""
    return create_engine(db_url)

def substitute_database_names(sql_script: str) -> str:
    """Replace {{ICAN_DB}} and {{RAHKARAN_DB}} placeholders with config values."""
    return (
        sql_script
        .replace("{{ICAN_DB}}", config.ICAN_DB)
        .replace("{{RAHKARAN_DB}}", config.RAHKARAN_DB)
    )

def execute_sql_file(conn, file_path):
    import os
    import re
    import config
    
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"SQL file not found: {file_path}")

    with open(file_path, 'r', encoding='utf-8-sig') as f:
        sql_script = f.read()

    # ==========================================
    # DYNAMIC SQL TEMPLATING:
    # Handle both double braces {{DB}} and single braces {DB} to be safe!
    # ==========================================
    sql_script = sql_script.replace('{{ICAN_DB}}', config.ICAN_DB)
    sql_script = sql_script.replace('{{RAHKARAN_DB}}', config.RAHKARAN_DB)
    sql_script = sql_script.replace('{ICAN_DB}', config.ICAN_DB)
    sql_script = sql_script.replace('{RAHKARAN_DB}', config.RAHKARAN_DB)

    batches = re.split(r'(?i)^\s*GO\s*$', sql_script, flags=re.MULTILINE)
    cursor = conn.cursor()
    
    try:
        for batch in batches:
            clean_batch = batch.strip()
            if clean_batch:
                cursor.execute(clean_batch)
                
                # CRITICAL FIX: Flush the output stream so pyodbc catches hidden SQL errors!
                while cursor.nextset():
                    pass
        
        conn.commit()
        print(f"✅ Successfully executed: {os.path.basename(file_path)}")
        
    except Exception as e:
        conn.rollback()
        print(f"❌ FAILED executing {os.path.basename(file_path)}")
        print(f"Error Details: {str(e)}")
        raise e