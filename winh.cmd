@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  WinPE Recovery Tool
echo ============================================================
echo   WinPE Recovery Tool
echo ============================================================
echo.
echo   [1] FIX    - Clear Windows Hello / Disable WHfB + Smart Card
echo   [2] REVERT - Re-enable Windows Hello / WHfB policies
echo.
set /p "Mode=Select option (1 or 2): "
if "%Mode%"=="1" goto detect_drive
if "%Mode%"=="2" goto detect_drive
echo [ERROR] Invalid selection.
pause
exit /b 1

::  DETECT OS DRIVE LETTER
::  Scans common letters for a live Windows SOFTWARE hive.
::  Avoids assuming C: which is often wrong under WinPE.
:detect_drive
echo.
echo Detecting Windows installation drive...
set "OsDrive="
for %%d in (C D E F G H I) do (
    if exist "%%d:\Windows\System32\config\SOFTWARE" (
        set "OsDrive=%%d:"
    )
)
if defined OsDrive (
    echo [INFO] Windows found on %OsDrive%
) else (
    echo [WARN] Could not auto-detect Windows drive (drive may be BitLocker locked).
    set "OsDrive=C:"
    set /p "OsDrive=Enter drive letter [default: C:]: "
    set "OsDrive=%OsDrive::=%"
    set "OsDrive=!OsDrive!:"
    echo [INFO] Using drive !OsDrive!
)
if "%Mode%"=="1" goto check_bitlocker_fix
if "%Mode%"=="2" goto check_bitlocker_revert

::  BITLOCKER UNLOCK  (shared by both modes)
::  Uses findstr /i instead of parsing token 2 on colon,
::  which breaks on localised output or multi-colon lines.
:check_bitlocker_fix
:check_bitlocker_revert
echo.
echo Checking BitLocker status on %OsDrive%...
set "Unlocked="
for /f "tokens=*" %%i in ('manage-bde -status %OsDrive% ^| findstr /i "Unlocked"') do set "Unlocked=1"
if defined Unlocked (
    echo The drive is already unlocked.
    if "%Mode%"=="1" goto clear_ngc
    if "%Mode%"=="2" goto load_hive_revert
)
echo.
manage-bde -protectors -get %OsDrive%
echo.
set /p "Machine=Enter BitLocker Recovery Key: "
echo Attempting to unlock %OsDrive%...
start /wait manage-bde -unlock %OsDrive% -recoverypassword "%Machine%"
if %errorlevel% neq 0 (
    echo [ERROR] Unlock failed. Verify the recovery key and try again.
    pause
    exit /b 1
)
if "%Mode%"=="1" goto clear_ngc
if "%Mode%"=="2" goto load_hive_revert

:: ============================================================
::  [MODE 1]  CLEAR NGC FOLDER
:: ============================================================
:clear_ngc
echo.
echo Clearing Windows Hello credentials (NGC)...
set "NgcPath=%OsDrive%\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"

if not exist "%NgcPath%" (
    echo [INFO] NGC folder not found - skipping.
    goto load_hive_fix
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

:: Delete all files recursively
del /f /s /q "%NgcPath%\*" 2>nul

:: Remove subdirectories - pushd avoids the quoted-glob expansion bug
:: where CMD does not expand wildcards inside quoted in() paths
pushd "%NgcPath%"
for /d %%i in (*) do rd /s /q "%%i" 2>nul
popd

echo [SUCCESS] Windows Hello credentials cleared.

::  [MODE 1]  LOAD HIVE AND DISABLE POLICIES
:load_hive_fix
echo.
echo Loading offline SOFTWARE hive...
reg load HKLM\Offline "%OsDrive%\Windows\System32\config\SOFTWARE"
if %errorlevel% neq 0 (
    echo [ERROR] Failed to load offline registry hive.
    pause
    exit /b 1
)

echo Disabling Windows Hello for Business and smart card enforcement...
reg add "HKLM\Offline\Policies\Microsoft\PassportForWork"                     /v Enabled             /t REG_DWORD /d 0 /f
reg add "HKLM\Offline\Policies\Microsoft\PassportForWork"                     /v UsePassportForWork  /t REG_DWORD /d 0 /f
reg add "HKLM\Offline\Policies\Microsoft\Windows\System"                      /v AllowDomainPINLogon /t REG_DWORD /d 0 /f
reg add "HKLM\Offline\Microsoft\Windows\CurrentVersion\Policies\System"       /v ScForceOption       /t REG_DWORD /d 0 /f

goto unload_hive

::  [MODE 2]  LOAD HIVE AND RESTORE POLICIES
:load_hive_revert
echo.
echo Loading offline SOFTWARE hive...
reg load HKLM\Offline "%OsDrive%\Windows\System32\config\SOFTWARE"
if %errorlevel% neq 0 (
    echo [ERROR] Failed to load offline registry hive.
    pause
    exit /b 1
)

echo Restoring Windows Hello for Business and smart card policies...
reg add "HKLM\Offline\Policies\Microsoft\PassportForWork"                     /v Enabled             /t REG_DWORD /d 1 /f
reg add "HKLM\Offline\Policies\Microsoft\PassportForWork"                     /v UsePassportForWork  /t REG_DWORD /d 1 /f
:: Delete AllowDomainPINLogon rather than flip it - absence restores default behaviour
reg delete "HKLM\Offline\Policies\Microsoft\Windows\System"                   /v AllowDomainPINLogon /f 2>nul
reg add "HKLM\Offline\Microsoft\Windows\CurrentVersion\Policies\System"       /v ScForceOption       /t REG_DWORD /d 1 /f

echo.
echo [INFO] NGC credentials cannot be restored - user must re-enrol
echo        Windows Hello on first login after reboot.

goto unload_hive

:unload_hive
echo.
echo Unloading offline registry hive...
set "Retries=0"
:unload_retry
reg unload HKLM\Offline >nul 2>&1
if %errorlevel% equ 0 goto unload_ok
set /a Retries+=1
if %Retries% geq 5 (
    echo [ERROR] Failed to unload hive after 5 attempts.
    echo         Do NOT reboot - registry corruption risk.
    echo         Try running: reg unload HKLM\Offline  manually.
    pause
    exit /b 1
)
echo [WARN] Hive busy, retrying in 3s... (%Retries%/5)
timeout /t 3 /nobreak >nul
goto unload_retry

:unload_ok
if "%Mode%"=="1" (
    echo [SUCCESS] Policies disabled and hive unloaded cleanly.
    echo.
    echo Remove WinPE media and reboot. Windows Hello will not prompt
    echo and smart card enforcement is off for the next boot.
) else (
    echo [SUCCESS] Policies restored and hive unloaded cleanly.
    echo.
    echo Remove WinPE media and reboot. User must re-enrol
    echo Windows Hello on first sign-in.
)
echo.
pause
exit /b 0
