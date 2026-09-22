@echo off

set DIRNAME=%~dp0
if "%JAVA_HOME%" == "" (
  set JAVA_EXE=java.exe
) else (
  set JAVA_EXE=%JAVA_HOME%\bin\java.exe
)

"%JAVA_EXE%" -Dorg.gradle.appname=gradlew -classpath "%DIRNAME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
if "%ERRORLEVEL%" == "0" goto mainEnd

:mainEnd
if "%OS%" == "Windows_NT" endlocal
exit /b %ERRORLEVEL%