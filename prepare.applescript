on run argv
	set windowTitle to item 1 of argv
	set keyCastrX to (item 2 of argv) as integer
	set keyCastrY to (item 3 of argv) as integer
	set demoPid to missing value

	tell application "System Events"
		repeat 100 times
			repeat with appProcess in (every application process whose name is "ghostty")
				tell appProcess
					if exists (first window whose name is windowTitle) then
						set frontmost to true
						set demoPid to unix id
						exit repeat
					end if
				end tell
			end repeat
			if demoPid is not missing value then exit repeat
			delay 0.1
		end repeat

		if demoPid is missing value then error "Timed out waiting for the demo Ghostty window."
		set frontmost of (first application process whose unix id is demoPid) to true
		repeat 50 times
			if exists application process "KeyCastr" then exit repeat
			delay 0.1
		end repeat
		if not (exists application process "KeyCastr") then error "Timed out waiting for KeyCastr."
		set keyCastrProcess to application process "KeyCastr"
		if name of menu item 3 of menu "KeyCastr" of menu bar item 1 of menu bar 2 of keyCastrProcess is "Start Casting" then
			error "KeyCastr is not casting. Grant it Input Monitoring access and restart it."
		end if
		set position of window 1 of keyCastrProcess to {keyCastrX, keyCastrY}
		return demoPid
	end tell
end run
