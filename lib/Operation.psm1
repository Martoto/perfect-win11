#Requires -Version 5.1
function Enter-PerfectWin11Operation {
    # Same name as the installer; Global coordinates this user's other sessions too.
    $suffix=$env:LOCALAPPDATA.ToLowerInvariant().Replace('\','_').Replace(':','_')
    $mutex=New-Object Threading.Mutex($false,('Global\PerfectWin11.Package.'+$suffix))
    $acquired=$false
    try {
        try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'Another Perfect Win11 setup, restore, install, or uninstall is running. Wait for it to finish, then retry.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}
function Exit-PerfectWin11Operation($Operation) {
    if ($Operation) { try { $Operation.ReleaseMutex() } finally { $Operation.Dispose() } }
}
Export-ModuleMember -Function Enter-PerfectWin11Operation,Exit-PerfectWin11Operation
