# This is to reduce complexity in Get-ProjectItems. If we support over 100 fields then we would need to run 2 cursors
$global:maxSupportedProjectFields = 100