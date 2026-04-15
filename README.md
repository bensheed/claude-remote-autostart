# claude-remote-autostart
PowerShell wrapper that keeps claude remote-control running on Windows. Auto-launches at logon via Task Scheduler with unique session names, restarts on crash with exponential backoff, enforces a per-hour launch ceiling and cross-restart giveup cooldown so transient bridge-API outages don't become a 60/hr relaunch hammer.
