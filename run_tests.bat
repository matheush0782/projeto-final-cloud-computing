@echo off
set PROJECT_DIR=C:\Users\mathe\Downloads\projeto-final-cloud-computing
cd /d %PROJECT_DIR%

echo === Git diff --check ===
git diff --check
if %errorlevel% equ 0 echo PASS

echo.
echo === bash -n scripts/concluir-projeto.sh ===
"C:\Program Files\Git\bin\bash.exe" -c "bash -n scripts/concluir-projeto.sh"
if %errorlevel% equ 0 echo PASS

echo.
echo === bash -n scripts/validar-fase6.sh ===
"C:\Program Files\Git\bin\bash.exe" -c "bash -n scripts/validar-fase6.sh"
if %errorlevel% equ 0 echo PASS

echo.
echo === bash -n tests/test_fase6.sh ===
"C:\Program Files\Git\bin\bash.exe" -c "bash -n tests/test_fase6.sh"
if %errorlevel% equ 0 echo PASS

echo.
echo === python3 -m pytest tests/test_scripts.py -v ===
python3 -m pytest tests/test_scripts.py -v

echo.
echo === bash tests/test_fase6.sh ===
"C:\Program Files\Git\bin\bash.exe" -c "bash tests/test_fase6.sh"

echo.
echo === bash scripts/concluir-projeto.sh --check ===
"C:\Program Files\Git\bin\bash.exe" -c "bash scripts/concluir-projeto.sh --check"

echo.
echo === bash scripts/concluir-projeto.sh --plan ===
"C:\Program Files\Git\bin\bash.exe" -c "bash scripts/concluir-projeto.sh --plan"