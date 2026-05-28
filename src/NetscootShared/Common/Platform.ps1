function Test-IsWindowsHost {
    # 5.1-safe: $IsWindows is an automatic var only on PowerShell 6+; on Windows PowerShell
    # 5.1 it is undefined and (under StrictMode) throws, so probe the edition first.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

# Path comparison must follow the host OS: Windows (and Windows PowerShell 5.1) are
# case-insensitive; Linux is case-sensitive. macOS is usually case-insensitive but we
# take the conservative (Ordinal) path off-Windows so we never wrongly merge two
# distinct projects - at worst we treat a case-only rename as distinct, which is safe.
$script:PathComparison = if (Test-IsWindowsHost) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
