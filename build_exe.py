import os
import secrets
import subprocess
import time

def build():
    print("="*50)
    print("🚀 INITIALIZING SECURE BUILD PROCESS")
    print("="*50)
    
    # 1. Generate unique password
    unique_password = secrets.token_urlsafe(8)
    
    # 2. Calculate expiration time (Current Unix Time + 3600 seconds)
    expiration_timestamp = time.time() + 3600

    with open("wizard.py", "r", encoding="utf-8") as f:
        wizard_code = f.read()

    # 3. Inject variables into the payload
    wizard_code = wizard_code.replace('%%GENERATED_PASSWORD%%', unique_password)
    wizard_code = wizard_code.replace('%%EXPIRATION_TIMESTAMP%%', str(expiration_timestamp))

    with open("wizard_build.py", "w", encoding="utf-8") as f:
        f.write(wizard_code)

    print(f"✅ Generated unique security key.")
    print(f"✅ Set executable validity to 1 hour from now.")
    print(f"📦 Compiling PyInstaller Executable... (This may take a minute)")

    subprocess.run([
        "pyinstaller", "--name", "IcanMigrationTool",
        "--onedir", 
        "--add-data", "sql_scripts;sql_scripts",
        "--add-data", "config.py.example;.",
        "--add-data", "pw-browsers;pw-browsers",
        "wizard_build.py"
    ], check=True)

    # Clean up build files
    if os.path.exists("wizard_build.py"):
        os.remove("wizard_build.py")
    if os.path.exists("wizard_build.spec"):
        os.remove("wizard_build.spec")

    dist_folder = os.path.join("dist", "IcanMigrationTool")

    print("\n" + "="*50)
    print("🎉 BUILD SUCCESSFUL!")
    print("="*50)
    print(f"YOUR EXECUTABLE PASSWORD:  {unique_password}")
    print(f"VALIDITY:                  Exactly 1 Hour from right now")
    print("="*50)
    print(f"The executable is located in: {dist_folder}")

if __name__ == "__main__":
    build()