# Explicit preview identity; preserve the caller's implementation choice.
$savedAcqImpl = [Environment]::GetEnvironmentVariable('ACQ_IMPL', 'Process')
try {
    $env:ACQ_IMPL = 'python'
    & (Join-Path $PSScriptRoot 'acq.ps1') @args
}
finally {
    [Environment]::SetEnvironmentVariable('ACQ_IMPL', $savedAcqImpl, 'Process')
}
exit $LASTEXITCODE
