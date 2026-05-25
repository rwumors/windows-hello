@echo off
setlocal enabledelayedexpansion

echo ============================================================
echo   WinPE Recovery Tool
echo ============================================================
echo.

:: ============================================================
::  BITLOCKER UNLOCK
:: ============================================================
echo Checking BitLocker status on C:...
set "Unlocked="
for /f "tokens=2 delims=:" %%i in ('manage-bde -status C: ^| find "Lock Status"') do set "LockStatus=%%i"
if defined Unlocked (
    echo The drive is already unlocked.
    goto clear_ngc
)
echo.
manage-bde -protectors -get C:
echo.
set /p "Machine=Enter BitLocker Recovery Key: "
echo Attempting to unlock C:...
start /wait manage-bde -unlock C: -recoverypassword "%Machine%"
if %errorlevel% neq 0 (
    echo [ERROR] Unlock failed. Verify the recovery key and try again.
    pause
    exit /b 1
)

:: ============================================================
::  CLEAR NGC FOLDER
:: ============================================================
:clear_ngc
echo.
echo Clearing Windows Hello credentials (NGC)...
set "NgcPath=C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
if not exist "%NgcPath%" (
    echo [INFO] NGC folder not found - skipping.
    goto disable_policies
)
takeown /f "%NgcPath%" /r /d y
if %errorlevel% neq 0 (
    echo [ERROR] takeown failed on NGC folder.
    pause
    exit /b 1
)
icacls "%NgcPath%" /grant Administrators:F /t
if %errorlevel% neq 0 (
    echo [ERROR] icacls failed on NGC folder.
    pause
    exit /b 1
)
del /f /s /q "%NgcPath%\*" 2>nul
pushd "%NgcPath%"
for /d %%i in (*) do rd /s /q "%%i" 2>nul
popd
echo [SUCCESS] Windows Hello credentials cleared.

:: ============================================================
::  DISABLE POLICIES
:: ============================================================
:disable_policies
echo.
echo Loading offline SOFTWARE hive...
reg load HKLM\Offline "C:\Windows\System32\config\SOFTWARE"
if %errorlevel% neq 0 (
    echo [ERROR] Failed to load offline registry hive.
    pause
    exit /b 1
)
echo Disabling Windows Hello for Business and smart card enforcement...
reg add "HKLM\Offline\Policies\Microsoft\PassportForWork"               /v Enabled             /t REG_DWORD /d 0 /f
reg add "HKLM\Offline\Policies\Microsoft\PassportForWork"               /v UsePassportForWork  /t REG_DWORD /d 0 /f
reg add "HKLM\Offline\Policies\Microsoft\Windows\System"                /v AllowDomainPINLogon /t REG_DWORD /d 0 /f
reg add "HKLM\Offline\Microsoft\Windows\CurrentVersion\Policies\System" /v ScForceOption       /t REG_DWORD /d 0 /f
call :unload_hive
echo.
echo [SUCCESS] Policies disabled.

:: ============================================================
::  PAUSE - let user reboot and test, or continue to revert
:: ============================================================
echo.
echo ============================================================
echo   FIX complete. Remove WinPE media and reboot to test.
echo   If the machine is working, close this window.
echo   If you need to REVERT the policy changes, press any key.
echo ============================================================
pause
echo.

:: ============================================================
::  REVERT POLICIES
::  NGC cannot be restored - user must re-enrol on next login
:: ============================================================
echo Loading offline SOFTWARE hive...
reg load HKLM\Offline "C:\Windows\System32\config\SOFTWARE"
if %errorlevel% neq 0 (
    echo [ERROR] Failed to load offline registry hive.
    pause
    exit /b 1
)
echo Restoring Windows Hello for Business and smart card policies...
reg add    "HKLM\Offline\Policies\Microsoft\PassportForWork"               /v Enabled             /t REG_DWORD /d 1 /f
reg add    "HKLM\Offline\Policies\Microsoft\PassportForWork"               /v UsePassportForWork  /t REG_DWORD /d 1 /f
reg delete "HKLM\Offline\Policies\Microsoft\Windows\System"                /v AllowDomainPINLogon /f 2>nul
reg delete "HKLM\Offline\Microsoft\Windows\CurrentVersion\Policies\System" /v ScForceOption       /f 2>nul
call :unload_hive
echo.
echo [SUCCESS] Policies reverted. User must re-enrol Windows Hello on next login.
echo.
pause
exit /b 0

:: ============================================================
::  UNLOAD HIVE SUBROUTINE (called via `call :unload_hive`)
:: ============================================================
:unload_hive
echo Unloading offline registry hive...
set "Retries=0"
:unload_retry
reg unload HKLM\Offline >nul 2>&1
if %errorlevel% equ 0 goto :eof
set /a Retries+=1
if %Retries% geq 5 (
    echo [ERROR] Failed to unload hive after 5 attempts.
    echo         Do NOT reboot - registry corruption risk.
    echo         Run manually: reg unload HKLM\Offline
    pause
    exit /b 1
)
echo [WARN] Hive busy, retrying in 3s... (%Retries%/5)
timeout /t 3 /nobreak >nul
goto unload_retry
