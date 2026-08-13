import os
import subprocess

def build():
    print("="*50)
    print("🚀 INITIALIZING BUILD PROCESS")
    print("="*50)
    
    print("📦 Compiling PyInstaller Executable... (This may take a minute)")

    # Call PyInstaller directly on your clean wizard.py
    subprocess.run([
        "pyinstaller", "--name", "IcanMigrationTool",
        "--onedir", 
        "--add-data", "sql_scripts;sql_scripts",
        "--add-data", "pw-browsers;pw-browsers",
        "wizard.py" 
    ], check=True)

    # Define the output directory where the .exe was just created
    dist_folder = os.path.join("dist", "IcanMigrationTool")

    # Generate the settings.txt file directly in the dist folder!
    settings_path = os.path.join(dist_folder, "settings.txt")
    template = (
        "# Database Migration Settings\n"
        "SERVER=127.0.0.1\n"
        "USERNAME=sa\n"
        "PASSWORD=\n"
        "ICAN_DB=ican\n"
        "RAHKARAN_DB=madani_sg3\n"
        "#CONTENT_FORMAT=docx\n"
        "#FARZIN_ROOT=D:\\Farzin\n"
    )
    
    # Ensure the folder exists before writing (just to be safe)
    os.makedirs(dist_folder, exist_ok=True)
    
    with open(settings_path, 'w', encoding='utf-8') as f:
        f.write(template)

    print("\n" + "="*50)
    print("🎉 BUILD SUCCESSFUL!")
    print("="*50)
    print(f"The executable and 'settings.txt' are now waiting for you in: ")
    print(f"-> {dist_folder}")
    print("="*50)

if __name__ == "__main__":
    build()