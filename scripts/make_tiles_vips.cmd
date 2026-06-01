@echo off

set src=capture_v1.jpg
set dest=../tiles/capture_v1

mkdir %dest%

vips dzsave %src% %dest% --depth onetile --layout dz --tile-size 512 --suffix .jpg[Q=75] --vips-progress

rename ..\tiles\capture_v1_files capture_v1

del ..\tiles\capture_v1.dzi
