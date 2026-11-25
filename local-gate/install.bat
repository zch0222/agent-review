@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem ==========================================================================
rem  local-gate installer for Windows (cmd or PowerShell)
rem  Installs the /gate skill and its subagents for Claude Code, Codex,
rem  Kimi Code (kcode), ZCode and DeepSeek Harness.
rem
rem    install.bat                          install for every tool found
rem    install.bat --target claude codex    install for the named tools
rem    install.bat --uninstall [--target ...]
rem    install.bat --dry-run
rem ==========================================================================

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "SKILL_SRC=%HERE%\skills\gate"
set "SUB_SRC=%HERE%\subagents"
set "ROLES=reviewer refuter security-reviewer"
set "MARK=.local-gate-install"
set "ALL_TARGETS=claude codex kcode zcode deepseek"
rem Codex, Kimi Code, ZCode and DeepSeek Harness all read ~/.agents/skills,
rem so they share one copy there; Claude Code gets its own copy.
set "SHARED_SKILL=%USERPROFILE%\.agents\skills\gate"

set "TARGETS="
set "ACTION=install"
set "DRY=0"
set "FORCE=0"

:parse
if "%~1"=="" goto parsed
set "ARG=%~1"
if /i "!ARG!"=="--target" goto opt_target
if /i "!ARG!"=="-t" goto opt_target
if /i "!ARG!"=="--uninstall" (set "ACTION=uninstall" & shift & goto parse)
if /i "!ARG!"=="--dry-run" (set "DRY=1" & shift & goto parse)
if /i "!ARG!"=="--force" (set "FORCE=1" & shift & goto parse)
if /i "!ARG!"=="-h" (call :usage & exit /b 0)
if /i "!ARG!"=="--help" (call :usage & exit /b 0)
echo Unknown option: !ARG!
call :usage
exit /b 2

:opt_target
shift
:opt_target_loop
if "%~1"=="" goto parse
set "V=%~1"
if "!V:~0,1!"=="-" goto parse
set "TARGETS=!TARGETS! !V!"
shift
goto opt_target_loop

:parsed
if not exist "%SKILL_SRC%\SKILL.md" (
  echo error: cannot find the skill folder next to this script
  exit /b 1
)
if defined TARGETS set "TARGETS=!TARGETS:,= !"

rem ---- resolve the target list ----
set "LIST="
set "HAS_ALL=0"
set "BAD="
if defined TARGETS (
  for %%A in (!TARGETS!) do (
    call :normalize %%A NT
    if "!NT!"=="" (
      if not defined BAD set "BAD=%%A"
    ) else if "!NT!"=="all" (
      set "HAS_ALL=1"
    ) else if not "!NT!"=="auto" (
      set "DUP=0"
      for %%B in (!LIST!) do if "%%B"=="!NT!" set "DUP=1"
      if "!DUP!"=="0" set "LIST=!LIST! !NT!"
    )
  )
)
rem exit only at top level: "exit /b" inside a for loop loses its code under "cmd /c"
if defined BAD goto bad_target
if "!HAS_ALL!"=="1" set "LIST=%ALL_TARGETS%"
if defined LIST goto have_list
for %%A in (%ALL_TARGETS%) do (
  call :home_of %%A HD
  if exist "!HD!\" set "LIST=!LIST! %%A"
)
if not defined LIST goto no_tool
echo detected:!LIST!
:have_list

rem ---- Git's sh.exe, used by the skill's helper script ----
set "SH_PATH=sh"
set "GIT_EXEC="
for /f "delims=" %%G in ('git --exec-path 2^>nul') do set "GIT_EXEC=%%G"
if defined GIT_EXEC (
  set "GIT_EXEC=!GIT_EXEC:/=\!"
  for %%R in ("!GIT_EXEC!\..\..\..") do set "GIT_ROOT=%%~fR"
  if exist "!GIT_ROOT!\bin\sh.exe" (
    set "SH_PATH=!GIT_ROOT!\bin\sh.exe"
  ) else if exist "!GIT_ROOT!\usr\bin\sh.exe" (
    set "SH_PATH=!GIT_ROOT!\usr\bin\sh.exe"
  )
)
set "SH_PATH=!SH_PATH:\=/!"

call :home_of claude CLAUDE_HOME
set "CLAUDE_SKILL=!CLAUDE_HOME!\skills\gate"
set "HAS_CLAUDE=0"
set "SHARED="
for %%A in (!LIST!) do (
  if "%%A"=="claude" (set "HAS_CLAUDE=1") else (set "SHARED=!SHARED! %%A")
)

if /i "!ACTION!"=="uninstall" goto do_uninstall

rem ---- install ----
set "OK_CLAUDE=1"
set "OK_SHARED=1"
if "!HAS_CLAUDE!"=="1" (
  echo == Claude Code skill
  call :install_skill "!CLAUDE_SKILL!" "claude"
  if errorlevel 1 set "OK_CLAUDE=0"
)
if defined SHARED (
  echo == Shared skill for:!SHARED!
  call :install_skill "!SHARED_SKILL!" "!SHARED!"
  if errorlevel 1 set "OK_SHARED=0"
)
for %%A in (!LIST!) do (
  set "GO=!OK_SHARED!"
  if "%%A"=="claude" set "GO=!OK_CLAUDE!"
  if "!GO!"=="1" (
    call :label_of %%A LBL
    call :home_of %%A HD
    echo == !LBL!: !HD!
    if not exist "!HD!\" echo   note: !HD! not found, the tool may not be installed
    call :write_agents %%A
    call :invoke_of %%A INV
    echo   run it with: !INV!
  )
)
echo.
echo Done. Commit locally, then run the skill by hand in your tool.
echo The first run creates %USERPROFILE%\.agent-review\profiles\[repo].yml - fill in its checks.
exit /b 0

:do_uninstall
for %%A in (!LIST!) do (
  call :label_of %%A LBL
  echo == !LBL!
  call :remove_agents %%A
)
if "!HAS_CLAUDE!"=="1" (
  echo == Claude Code skill
  call :remove_skill "!CLAUDE_SKILL!" "claude"
)
if defined SHARED (
  echo == Shared skill
  call :remove_skill "!SHARED_SKILL!" "!SHARED!"
)
exit /b 0

:bad_target
echo error: unknown target !BAD!
call :usage
exit /b 2

:no_tool
echo No supported tool found. Use --target to choose one.
exit /b 1

rem ======================= subroutines =======================

:usage
echo Usage: install.bat [--target NAME ...] [--uninstall] [--dry-run] [--force]
echo.
echo   NAME         claude, codex, kcode (Kimi Code), zcode, deepseek (DeepSeek Harness), or all.
echo                Give several names separated by spaces. Default: every tool found.
echo   --uninstall  remove what this script installed
echo   --dry-run    show the actions without changing anything
echo   --force      replace a "gate" skill or gate-* agent this script did not install
echo.
echo   Env overrides: CLAUDE_CONFIG_DIR CODEX_HOME KIMI_CODE_HOME ZCODE_STORAGE_DIR DSH_HOME
exit /b 0

:normalize
set "%~2="
if /i "%~1"=="claude" set "%~2=claude"
if /i "%~1"=="claude-code" set "%~2=claude"
if /i "%~1"=="codex" set "%~2=codex"
if /i "%~1"=="kcode" set "%~2=kcode"
if /i "%~1"=="kimi" set "%~2=kcode"
if /i "%~1"=="kimi-code" set "%~2=kcode"
if /i "%~1"=="zcode" set "%~2=zcode"
if /i "%~1"=="deepseek" set "%~2=deepseek"
if /i "%~1"=="dsh" set "%~2=deepseek"
if /i "%~1"=="deepseek-harness" set "%~2=deepseek"
if /i "%~1"=="all" set "%~2=all"
if /i "%~1"=="auto" set "%~2=auto"
exit /b 0

:home_of
if /i "%~1"=="claude" (if defined CLAUDE_CONFIG_DIR (set "%~2=!CLAUDE_CONFIG_DIR!") else (set "%~2=!USERPROFILE!\.claude"))
if /i "%~1"=="codex" (if defined CODEX_HOME (set "%~2=!CODEX_HOME!") else (set "%~2=!USERPROFILE!\.codex"))
if /i "%~1"=="kcode" (if defined KIMI_CODE_HOME (set "%~2=!KIMI_CODE_HOME!") else (set "%~2=!USERPROFILE!\.kimi-code"))
if /i "%~1"=="zcode" (if defined ZCODE_STORAGE_DIR (set "%~2=!ZCODE_STORAGE_DIR!") else (set "%~2=!USERPROFILE!\.zcode"))
if /i "%~1"=="deepseek" (if defined DSH_HOME (set "%~2=!DSH_HOME!") else (set "%~2=!USERPROFILE!\.dsh"))
exit /b 0

:label_of
if /i "%~1"=="claude" set "%~2=Claude Code"
if /i "%~1"=="codex" set "%~2=Codex"
if /i "%~1"=="kcode" set "%~2=Kimi Code"
if /i "%~1"=="zcode" set "%~2=ZCode"
if /i "%~1"=="deepseek" set "%~2=DeepSeek Harness"
exit /b 0

:invoke_of
set "%~2=/gate"
if /i "%~1"=="codex" set "%~2=$gate"
if /i "%~1"=="kcode" set "%~2=/skill:gate"
exit /b 0

:install_skill
rem install_skill DEST "TARGETS"
set "SD=%~1"
set "ST=%~2"
echo   skill: !SD!
if exist "!SD!\" if not exist "!SD!\%MARK%" if "!FORCE!"=="0" (
  echo   skip: !SD! exists and was not installed by this script, use --force to replace it
  exit /b 1
)
if "!DRY!"=="1" (
  echo   [dry-run] copy skills\gate to !SD!
  exit /b 0
)
set "OLDMARK=%TEMP%\local-gate-%RANDOM%%RANDOM%.txt"
type nul > "!OLDMARK!"
if exist "!SD!\%MARK%" findstr /b /c:"target=" "!SD!\%MARK%" > "!OLDMARK!"
if exist "!SD!\" rmdir /s /q "!SD!"
xcopy "!SKILL_SRC!" "!SD!\" /E /I /Y /Q >nul
if errorlevel 1 (
  echo   error: cannot copy the skill to !SD!
  del "!OLDMARK!" >nul 2>&1
  exit /b 1
)
call :fill "!SD!"
if errorlevel 1 echo   warning: could not fill the paths in !SD!\SKILL.md
> "!SD!\%MARK%" echo installed-by=local-gate
type "!OLDMARK!" >> "!SD!\%MARK%"
for %%X in (!ST!) do (
  findstr /x /c:"target=%%X" "!OLDMARK!" >nul 2>&1
  if errorlevel 1 >> "!SD!\%MARK%" echo target=%%X
)
del "!OLDMARK!" >nul 2>&1
exit /b 0

:fill
rem Replace {{SKILL_DIR}} and {{SH}} in SKILL.md; write UTF-8 without BOM.
set "FD=%~1"
set "FD_FWD=!FD:\=/!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path '!FD!' 'SKILL.md'; $t = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8); $t = $t.Replace('{{SKILL_DIR}}', '!FD_FWD!').Replace('{{SH}}', '!SH_PATH!'); [IO.File]::WriteAllText($f, $t, (New-Object Text.UTF8Encoding $false))"
exit /b !errorlevel!

:remove_skill
rem remove_skill DEST "TARGETS"
set "SD=%~1"
set "ST=%~2"
if not exist "!SD!\%MARK%" (
  if exist "!SD!\" echo   kept !SD!, it was not installed by this script
  exit /b 0
)
set "NEWMARK=%TEMP%\local-gate-%RANDOM%%RANDOM%.txt"
copy /y "!SD!\%MARK%" "!NEWMARK!" >nul
for %%X in (!ST!) do (
  findstr /v /x /c:"target=%%X" "!NEWMARK!" > "!NEWMARK!.tmp"
  move /y "!NEWMARK!.tmp" "!NEWMARK!" >nul
)
findstr /b /c:"target=" "!NEWMARK!" >nul 2>&1
if errorlevel 1 (
  if "!DRY!"=="1" (
    echo   [dry-run] remove !SD!
  ) else (
    rmdir /s /q "!SD!"
    echo   removed !SD!
  )
) else (
  if "!DRY!"=="1" (
    echo   [dry-run] keep !SD!, other tools still use it
  ) else (
    copy /y "!NEWMARK!" "!SD!\%MARK%" >nul
    echo   kept !SD!, other tools still use it
  )
)
del "!NEWMARK!" >nul 2>&1
exit /b 0

:write_agents
rem write_agents TARGET
set "WT=%~1"
set "KIND="
if /i "%WT%"=="claude" set "KIND=claude"
if /i "%WT%"=="codex" set "KIND=codex"
if /i "%WT%"=="kcode" set "KIND=markdown"
if /i "%WT%"=="zcode" set "KIND=markdown"
if not defined KIND (
  echo   subagents: none needed, the skill uses the built-in subagent tool
  exit /b 0
)
call :home_of %WT% WH
set "AD=!WH!\agents"
if "!DRY!"=="0" if not exist "!AD!\" mkdir "!AD!"
for %%R in (%ROLES%) do (
  if "!KIND!"=="codex" (
    set "OUT=!AD!\gate-%%R.toml"
    set "HEADF=!SUB_SRC!\codex\gate-%%R.head.toml"
  ) else (
    set "OUT=!AD!\gate-%%R.md"
    set "HEADF=!SUB_SRC!\!KIND!\gate-%%R.head.md"
  )
  set "SKIP=0"
  if exist "!OUT!" (
    findstr /c:"installed-by: local-gate" "!OUT!" >nul 2>&1
    if errorlevel 1 if "!FORCE!"=="0" set "SKIP=1"
  )
  if "!SKIP!"=="1" (
    echo   skip: !OUT! exists and was not installed by this script
  ) else if "!DRY!"=="1" (
    echo   [dry-run] write !OUT!
  ) else (
    if "!KIND!"=="codex" (
      copy /y /b "!HEADF!"+"!SKILL_SRC!\roles\%%R.md"+"!SUB_SRC!\codex\tail.toml" "!OUT!" >nul
    ) else (
      copy /y /b "!HEADF!"+"!SKILL_SRC!\roles\%%R.md" "!OUT!" >nul
    )
    if errorlevel 1 (echo   error: cannot write !OUT!) else (echo   agent: !OUT!)
  )
)
exit /b 0

:remove_agents
rem remove_agents TARGET
call :home_of %~1 RH
for %%R in (%ROLES%) do (
  for %%E in (md toml) do (
    set "OUT=!RH!\agents\gate-%%R.%%E"
    if exist "!OUT!" (
      findstr /c:"installed-by: local-gate" "!OUT!" >nul 2>&1
      if not errorlevel 1 (
        if "!DRY!"=="1" (
          echo   [dry-run] remove !OUT!
        ) else (
          del /q "!OUT!"
          echo   removed !OUT!
        )
      )
    )
  )
)
exit /b 0
