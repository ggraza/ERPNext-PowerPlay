@echo off
echo off
cls
setlocal EnableDelayedExpansion
title ERPNext PowerPlay Update Publisher

REM ============================================================
REM  ERPNext PowerPlay Update Publisher
REM  Double-click to build, pack and upload to update server.
REM
REM  Prerequisites:
REM    dotnet tool install -g vpk
REM    WinSCP installed at default path
REM ============================================================

REM -- Resolve paths relative to this batch file location -----
set REPOROOT=%~dp0
set CSPROJ=%REPOROOT%ERPNext PowerPlay.csproj
set PUBLISHDIR=%REPOROOT%publish_output
set OUTPUTDIR=%REPOROOT%publish

REM -- FTP settings --------------------------------------------
set FTP_HOST=ftp.cecypo.tech
set FTP_USER=Updates@cecypo.com
set FTP_PASS=N0thing777
set FTP_REMOTEPATH=/PowerPlay/

set WINSCP="C:\Program Files (x86)\WinSCP\WinSCP.com"

REM ============================================================
REM  Read version from .csproj <Version> element.
REM  Extracts first 3 segments (1.0.9.0 -> 1.0.9) for Velopack.
REM ============================================================
set CSPROJ_PATH=%CSPROJ%
set VERSION=
powershell -NoProfile -Command "[regex]::Match((gc $env:CSPROJ_PATH), '<Version>(\d+\.\d+\.\d+)').Groups[1].Value" > "%TEMP%\ppver.txt"
set /p VERSION= < "%TEMP%\ppver.txt"
del "%TEMP%\ppver.txt" 2>nul

if "!VERSION!"=="" (
    echo ERROR: Could not read version from .csproj
    echo Expected a line like:  ^<Version^>1.0.9.0^</Version^>
    echo File: %CSPROJ%
    pause
    exit /b 1
)

REM ============================================================
REM  Sanity check
REM ============================================================
if not exist %WINSCP% (
    echo ERROR: WinSCP not found at %WINSCP%
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  ERPNext PowerPlay Update Publisher
echo  Version : !VERSION!
echo  Publish : %PUBLISHDIR%
echo  Output  : %OUTPUTDIR%
echo  Upload  : ftp://%FTP_HOST%%FTP_REMOTEPATH%
echo ============================================================
echo.

REM ============================================================
REM  Collect release notes (injected into notice.html later)
REM  Type each change and press ENTER.
REM  Leave the line blank and press ENTER when finished.
REM ============================================================
set "NOTESFILE=%TEMP%\powerplay_notes.txt"
del "%NOTESFILE%" 2>nul
echo Enter release notes for version !VERSION!:
echo (One item per line. Blank line to finish.)
echo.
:notes_loop
set "NOTE_LINE="
set /p "NOTE_LINE=  > "
if "!NOTE_LINE!"=="" goto notes_done
>>"!NOTESFILE!" echo !NOTE_LINE!
goto notes_loop
:notes_done
echo.

REM ============================================================
REM  Step 1: Fetch previous release from server (for delta)
REM  Non-fatal if server is empty (first publish).
REM ============================================================
echo [1/5] Fetching previous release from server for delta generation...
if not exist "%OUTPUTDIR%" mkdir "%OUTPUTDIR%"

setlocal DisableDelayedExpansion
(
    echo open ftp://%FTP_HOST%/ -username=%FTP_USER% -password=%FTP_PASS%
    echo synchronize local "%OUTPUTDIR%" "%FTP_REMOTEPATH%"
    echo exit
) > "%TEMP%\vpk_download_script.txt"
endlocal

%WINSCP% /log="%REPOROOT%winscp_download.log" /script="%TEMP%\vpk_download_script.txt"
del "%TEMP%\vpk_download_script.txt" 2>nul
REM (non-fatal: if server empty we get full package instead of delta)
echo Previous release fetch complete (or skipped if first publish).
echo.
REM ============================================================
REM  Step 2: dotnet publish (self-contained, win-x64)
REM ============================================================
echo [2/5] Publishing...
if exist "%PUBLISHDIR%" rmdir /s /q "%PUBLISHDIR%"

dotnet publish "%CSPROJ%" -c Release -r win-x64 --self-contained true -o "%PUBLISHDIR%"

if errorlevel 1 (
    echo.
    echo ERROR: dotnet publish failed. See above for details.
    pause
    exit /b 1
)
echo.

REM ============================================================
REM  Step 2b: Write flags.ini into publish directory
REM ============================================================
echo [2b] Writing flags.ini...
(
    echo [Flags]
    echo Update=1
) > "%PUBLISHDIR%\flags.ini"
echo flags.ini written.
echo.

REM ============================================================
REM  Step 3: Pack with Velopack
REM ============================================================
echo [3/5] Packing...
vpk pack ^
    --packId ERPNextPowerPlay ^
    --packVersion !VERSION! ^
    --packDir "%PUBLISHDIR%" ^
    --mainExe "ERPNext PowerPlay.exe" ^
    --outputDir "%OUTPUTDIR%"

if errorlevel 1 (
    echo.
    echo ERROR: vpk pack failed. See above for details.
    pause
    exit /b 1
)

echo.
echo Pack complete. Files in %OUTPUTDIR%:
dir /b "%OUTPUTDIR%"
echo.
REM ============================================================
REM  Step 3b: Inject version into notice.html
REM ============================================================
echo [3b] Building notice.html for version !VERSION!...
if not exist "%REPOROOT%notice.html" (
    echo WARNING: notice.html not found - skipping notice upload.
) else (
    set "PS_VERSION=!VERSION!"
    set "PS_NOTES=%NOTESFILE%"
    set "PS_SRC=%REPOROOT%notice.html"
    set "PS_OUT=%OUTPUTDIR%\notice.html"
    powershell -NoProfile -Command "$lt=[char]60; $gt=[char]62; $q=[char]34; $meta=$lt+'meta name='+$q+'version'+$q+' content='+$q+$env:PS_VERSION+$q+$gt; $nf=$env:PS_NOTES; $oli=$lt+'li'+$gt; $cli=$lt+'/li'+$gt; $li='        '+$oli+'No changes listed.'+$cli; if(Test-Path $nf){ $ln=[System.IO.File]::ReadAllLines($nf); if($ln.Count -gt 0){ $li=""; foreach($l in $ln){ $li+='        '+$oli+$l+$cli+[char]10 }; $li=$li.TrimEnd() } }; $html=[System.IO.File]::ReadAllText($env:PS_SRC); $html=$html -replace '{{VERSION_META_PLACEHOLDER}}',$meta; $html=$html -replace '{{CHANGES_PLACEHOLDER}}',$li; $html=$html -replace '{{VERSION_PLACEHOLDER}}',$env:PS_VERSION; [System.IO.File]::WriteAllText($env:PS_OUT,$html,[System.Text.Encoding]::UTF8)"
    if errorlevel 1 (
        echo ERROR: Failed to build notice.html
    ) else (
        echo notice.html written to %OUTPUTDIR%\notice.html
    )
)
echo.

REM ============================================================
REM  Step 4: Clean up old packages
REM ============================================================
echo [4/5] Removing old packages from local publish folder...
for %%F in ("%OUTPUTDIR%\*.nupkg") do (
    echo %%~nxF | findstr /l /c:"ERPNextPowerPlay-!VERSION!" >nul
    if errorlevel 1 (
        echo   Deleting old: %%~nxF
        del "%%F"
    )
)
echo.
echo Files remaining in %OUTPUTDIR%:
dir /b "%OUTPUTDIR%"
echo.

REM ============================================================
REM  Step 5: Upload via WinSCP FTP
REM ============================================================
echo [5/5] Uploading to %FTP_HOST%%FTP_REMOTEPATH% ...

setlocal DisableDelayedExpansion
(
    echo open ftp://%FTP_HOST%/ -username=%FTP_USER% -password=%FTP_PASS%
    echo synchronize remote -delete "%OUTPUTDIR%" "%FTP_REMOTEPATH%"
    echo exit
) > "%TEMP%\vpk_winscp_script.txt"
endlocal

echo --- WinSCP script contents ---
type "%TEMP%\vpk_winscp_script.txt"
echo --- end ---
echo.

%WINSCP% /log="%REPOROOT%winscp_upload.log" /script="%TEMP%\vpk_winscp_script.txt"
set WINSCP_ERR=%ERRORLEVEL%
del "%TEMP%\vpk_winscp_script.txt" 2>nul

if %WINSCP_ERR% neq 0 (
    echo.
    echo ERROR: WinSCP upload failed. Check winscp_upload.log for details.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Done. ERPNext PowerPlay !VERSION! published successfully.
echo  Old packages removed from local publish\ and FTP server.
echo  Check winscp_download.log / winscp_upload.log for details.
echo ============================================================
pause
