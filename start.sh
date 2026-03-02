@echo off
REM ─────────────────────────────────────────────────────────────────
REM  AgroMercados — Script de Arranque Windows
REM  Edita la línea SET API_KEY con tu clave de Alpha Vantage
REM  Obtén tu clave gratis en: https://www.alphavantage.co/support/#api-key
REM ─────────────────────────────────────────────────────────────────

SET API_KEY=PEGA_TU_CLAVE_AQUI

echo.
echo  ╔══════════════════════════════════════════════╗
echo  ║       AgroMercados · Latinoamérica           ║
echo  ║       Dashboard Datos Diarios Reales         ║
echo  ╚══════════════════════════════════════════════╝
echo.

IF "%API_KEY%"=="PEGA_TU_CLAVE_AQUI" (
    echo  ERROR: No has configurado tu clave de Alpha Vantage
    echo.
    echo  1. Ve a: https://www.alphavantage.co/support/#api-key
    echo  2. Registrate gratis
    echo  3. Edita start.bat y reemplaza PEGA_TU_CLAVE_AQUI
    echo.
    pause
    exit /b 1
)

echo  Verificando Python...
python --version >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo  ERROR: Python no encontrado. Instala desde python.org
    pause
    exit /b 1
)

echo  Instalando dependencias si es necesario...
pip install flask requests --quiet

echo  Iniciando servidor...
echo  Dashboard: http://localhost:5000
echo.

REM Abrir navegador
start "" "http://localhost:5000"

REM Iniciar servidor
python server.py %API_KEY%
pause
