@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul || (echo Install Python 3.11+ from https://www.python.org/downloads/windows/ & pause & exit /b 1)
py -3 -c "import sys; assert sys.version_info >= (3,11), 'Python 3.11+ required'" || exit /b 1
if not exist .venv\Scripts\python.exe py -3 -m venv .venv
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m pip install -r requirements.txt
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m unittest discover -s tests -v
if errorlevel 1 exit /b 1
echo Ready. Run run.cmd. Tesseract and Ollama are optional manual installs.
pause
