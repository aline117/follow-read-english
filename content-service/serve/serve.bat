@echo off
REM 家园局域网内容服务（Windows 启动器）
REM 默认 Node；可用 --runtime python 切到 Python。
REM 用法：serve.bat [--runtime node^|python^|auto] [serve 参数...]
setlocal EnableExtensions
cd /d "%~dp0"

set "RUNTIME=node"
set "ARGS="

:parse
if "%~1"=="" goto run
if /I "%~1"=="--runtime" (
  if "%~2"=="" (
    echo 用法：serve.bat [--runtime node^|python^|auto] [serve 参数...]
    exit /b 2
  )
  set "RUNTIME=%~2"
  shift
  shift
  goto parse
)
set "FIRST=%~1"
if /I "%FIRST:~0,10%"=="--runtime=" (
  set "RUNTIME=%FIRST:~10%"
  shift
  goto parse
)
REM 用 %1 而不是 %~1，保留路径参数两侧的引号
set "ARGS=%ARGS% %1"
shift
goto parse

:run
if /I "%RUNTIME%"=="auto" goto auto
if /I "%RUNTIME%"=="python" goto python
if /I "%RUNTIME%"=="node" goto node
echo 未知 runtime：%RUNTIME%（可选 node / python / auto）
exit /b 2

:auto
where py >nul 2>nul
if not errorlevel 1 goto python
where python >nul 2>nul
if not errorlevel 1 goto python
set "RUNTIME=node"
goto node

:python
where py >nul 2>nul
if not errorlevel 1 (
  py -3 serve.py %ARGS%
  goto end
)
where python >nul 2>nul
if not errorlevel 1 (
  python serve.py %ARGS%
  goto end
)
echo 找不到 Python；请安装 Python 3，或改用 --runtime node。
exit /b 1

:node
where node >nul 2>nul
if errorlevel 1 (
  echo 找不到 Node.js；请安装 Node，或改用 --runtime python。
  exit /b 1
)
node serve.js %ARGS%
goto end

:end
if errorlevel 1 (
  echo.
  echo 服务异常退出。检查运行时是否可用，或看上面的错误。
  pause
)
