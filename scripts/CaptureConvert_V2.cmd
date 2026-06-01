@echo off
setlocal enabledelayedexpansion

set srcdir=E:\Temp\Capture_V2
set dstdir=E:\Temp\Tiles_V2

set chunkSize=9375
set tileSize=4096
set tw=32
set th=15
set x0=-41
set y0=39

set SIZE=512

set /a th_minus_1=%th%-1
set /a tw_minus_1=%tw%-1

set k=0

cd /d %srcdir%

if not exist row_0.v (
	for /l %%c in (0,1,%th_minus_1%) do (
		set row_files=
		for /l %%r in (0,1,%tw_minus_1%) do (

			set /a "x=%x0% + %%r"
			set /a "y=%y0% + %%c"

			set src=Chunk_%chunkSize%_%tileSize%p_!x!_!y!.png

			if defined row_files (
				set "row_files=!row_files! !src!"
			) else (
				set "row_files=!src!"
			)
		)
		echo !row_files!
		vips arrayjoin "!row_files!" row_%%c.v --across 32
	)
)

if not exist merged.v (

	set all_rows=
	for /l %%c in (0,1,%th_minus_1%) do (
		if defined all_rows (
			set "all_rows=!all_rows! row_%%c.v"
		) else (
			set "all_rows=row_%%c.v"
		)
	)

	vips arrayjoin "!all_rows!" merged.v --across 1  --vips-progress
)

if not exist alpha.v (
	vips extract_band mask.png a.v 3
	vips resize a.v alpha.v 32 --vips-progress
)

if not exist masked.v (
	vips extract_band merged.v r.v 0 --vips-progress
	vips extract_band merged.v g.v 1 --vips-progress
	vips extract_band merged.v b.v 2 --vips-progress
	vips bandjoin "r.v g.v b.v alpha.v" masked.v --vips-progress
)

if not exist %dstdir% (
	mkdir %dstdir% 2>nul
	vips dzsave masked.v %dstdir% --layout google --tile-size 512  --background "0 0 0 0" --suffix .webp[Q=75] --centre --vips-progress
)

