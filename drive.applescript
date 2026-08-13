on focusDemo(demoPid)
	tell application "System Events"
		set frontmost of (first application process whose unix id is demoPid) to true
		repeat 20 times
			set frontPid to unix id of first application process whose frontmost is true
			if frontPid = demoPid then return
			delay 0.1
		end repeat
		error "Could not focus the demo Ghostty process."
	end tell
end focusDemo

on setCursor(nvimPath, socketPath, rowNumber, columnNumber)
	do shell script quoted form of nvimPath & " --server " & quoted form of socketPath & " --remote-expr " & quoted form of ("execute('call cursor(" & rowNumber & ", " & columnNumber & ")')")
end setCursor

on run argv
	set demoPid to (item 1 of argv) as integer
	set nvimPath to item 2 of argv
	set socketPath to item 3 of argv

	focusDemo(demoPid)
	delay 0.5
	tell application "System Events" to keystroke "7w"
	delay 0.8
	tell application "System Events" to keystroke "2b"
	delay 0.8
	tell application "System Events" to keystroke "2e"
	delay 0.8
	tell application "System Events" to keystroke "ge"
	delay 0.8

	setCursor(nvimPath, socketPath, 5, 35)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "viw"
	delay 0.9
	tell application "System Events" to key code 53
	delay 0.3
	tell application "System Events" to keystroke "vaw"
	delay 0.9
	tell application "System Events" to key code 53
	delay 0.4

	setCursor(nvimPath, socketPath, 8, 1)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "12w"
	delay 0.9
	tell application "System Events" to keystroke "v3aw"
	delay 0.9
	tell application "System Events" to key code 53
	delay 0.3
	setCursor(nvimPath, socketPath, 8, 44)
	focusDemo(demoPid)
	tell application "System Events"
		keystroke "c4aw"
		delay 0.25
		keystroke "draft "
		delay 0.25
		key code 53
	end tell
	delay 0.9

	setCursor(nvimPath, socketPath, 11, 1)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "9w"
	delay 0.7
	tell application "System Events" to keystroke "v2aw"
	delay 0.7
	tell application "System Events" to key code 53
	delay 0.25
	tell application "System Events"
		keystroke "c3aw"
		delay 0.2
		keystroke "edited "
		delay 0.2
		key code 53
	end tell
	delay 0.7

	setCursor(nvimPath, socketPath, 14, 1)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "10w"
	delay 0.7
	tell application "System Events" to keystroke "v2aw"
	delay 0.7
	tell application "System Events" to key code 53
	delay 0.25
	tell application "System Events"
		keystroke "c3aw"
		delay 0.2
		keystroke "revised "
		delay 0.2
		key code 53
	end tell
	delay 0.7

	setCursor(nvimPath, socketPath, 17, 30)
	focusDemo(demoPid)
	tell application "System Events"
		keystroke "c2aw"
		delay 0.25
		keystroke "kana "
		delay 0.25
		key code 53
	end tell
	delay 0.9

	setCursor(nvimPath, socketPath, 17, 36)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "d2e"
	delay 0.9
	tell application "System Events" to keystroke "u"
	delay 0.3
	setCursor(nvimPath, socketPath, 17, 73)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "d2ge"
	delay 0.9
	tell application "System Events" to keystroke "u"
	delay 0.4

	setCursor(nvimPath, socketPath, 20, 1)
	focusDemo(demoPid)
	tell application "System Events" to keystroke "2)"
	delay 0.9
	tell application "System Events" to keystroke "("
	delay 0.9
	tell application "System Events" to keystroke "vis"
	delay 0.9
	tell application "System Events" to key code 53
	delay 0.3
	tell application "System Events" to keystroke "vas"
	delay 0.9
	tell application "System Events" to key code 53
	delay 0.3
	tell application "System Events"
		keystroke "cis"
		delay 0.25
		keystroke "Rewritten with smart boundaries."
		delay 0.25
		key code 53
	end tell
	delay 0.9

	setCursor(nvimPath, socketPath, 20, 1)
	focusDemo(demoPid)
	tell application "System Events" to keystroke ")"
	delay 0.3
	tell application "System Events" to keystroke "das"
	delay 1
end run
