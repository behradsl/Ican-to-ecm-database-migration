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

def execute_sql_file(conn, file_path):
    """
    Reads a .sql file, splits it by 'GO' statements, 
    and safely executes the batches within a transaction.
    """
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"SQL file not found: {file_path}")

    with open(file_path, 'r', encoding='utf-8-sig') as f:
        sql_script = f.read()

    # Split the script by GO (case-insensitive, whole word)
    # This prevents pyodbc from crashing on multi-batch scripts
    batches = re.split(r'(?i)^\s*GO\s*$', sql_script, flags=re.MULTILINE)

    cursor = conn.cursor()
    
    try:
        for batch in batches:
            clean_batch = batch.strip()
            if clean_batch:
                cursor.execute(clean_batch)
        
        # Commit the transaction if all batches succeed
        conn.commit()
        print(f"✅ Successfully executed: {os.path.basename(file_path)}")
        
    except Exception as e:
        # If any batch fails, rollback everything
        conn.rollback()
        print(f"❌ FAILED executing {os.path.basename(file_path)}")
        print(f"Error Details: {str(e)}")
        raise e  # Re-raise to stop the main pipeline