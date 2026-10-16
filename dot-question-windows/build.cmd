@echo off
setlocal
cd /d "%~dp0"
if not exist .venv\Scripts\python.exe (echo Run setup.cmd first. & pause & exit /b 1)
.venv\Scripts\python.exe -m pip install -r requirements-build.txt
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m unittest discover -s tests -v
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m PyInstaller --noconfirm --clean --windowed --onedir --name DotQuestion app.py
if errorlevel 1 exit /b 1
echo Output: dist\DotQuestion\DotQuestion.exe. Keep the entire folder together.
pause
