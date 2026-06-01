@echo off
setlocal enabledelayedexpansion

cd Capture

set SIZE=16
set OUTPUT=%~dp0\output.jpg
set IMAGES=

for /f "delims=" %%f in ('powershell -command "$files = Get-ChildItem *.png; $sorted = $files | ForEach-Object { $name = $_.Name; if ($name -match 'Chunk_\d+_\d+p_(-?\d+)_(\d+)\.png') { [PSCustomObject]@{ Name=$name; First=[int]$matches[2]; Second=[int]$matches[1] } } } | Sort-Object First, Second | Select-Object -ExpandProperty Name; $sorted -join '\" \"'"') do (
    set IMAGES=!IMAGES! "%%f"
)

rem echo %images% >%~dp0\images.txt

magick montage %IMAGES% -tile %SIZE%x%SIZE% -geometry +0+0 -background black -gravity center %OUTPUT%
