@echo off
REM 家园局域网内容服务（Windows，需要先装 Node.js）
REM 双击运行；关掉窗口即停止服务。
cd /d "%~dp0"
node serve.js %*
if errorlevel 1 (
  echo.
  echo 服务异常退出。检查是否已安装 Node.js：node -v
  pause
)
