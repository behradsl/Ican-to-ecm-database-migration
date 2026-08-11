import pyodbc
import urllib.parse
from sqlalchemy import create_engine
import config

def get_rahkaran_conn():
    """Establishes a connection to the Rahkaran database dynamically."""
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={config.DB_SERVER};"
        f"DATABASE={config.RAHKARAN_DB};"
        f"UID={config.DB_USER};"
        f"PWD={config.DB_PASSWORD};"
        f"TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str)

def get_ican_conn():
    """Establishes a connection to the ICAN database dynamically."""
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={config.DB_SERVER};"
        f"DATABASE={config.ICAN_DB};"
        f"UID={config.DB_USER};"
        f"PWD={config.DB_PASSWORD};"
        f"TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str)

def get_sqlalchemy_engine(db_name=None):
    """Establishes a SQLAlchemy engine for Pandas binary operations."""
    # If a specific DB isn't requested, default to the Rahkaran database
    target_db = db_name if db_name else config.RAHKARAN_DB
    
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={config.DB_SERVER};"
        f"DATABASE={target_db};"
        f"UID={config.DB_USER};"
        f"PWD={config.DB_PASSWORD};"
        f"TrustServerCertificate=yes;"
    )
    
    # SQLAlchemy requires the connection string to be URL-encoded
    quoted_conn_str = urllib.parse.quote_plus(conn_str)
    
    # fast_executemany=True drastically speeds up binary file inserts!
    engine = create_engine(
        f"mssql+pyodbc:///?odbc_connect={quoted_conn_str}", 
        fast_executemany=True
    )
    return engine