#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $SaveDirectory
)

$scriptUri = 'https://api.github.com/repos/EthenGod/p5r-royal-resume/contents/p5r-royal-resume.ps1?ref=main&run=' + [guid]::NewGuid().ToString('N')
$source = Invoke-RestMethod -UseBasicParsing $scriptUri -Headers @{ Accept = 'application/vnd.github.raw+json' } -ErrorAction Stop
& ([ScriptBlock]::Create($source.TrimStart([char]0xFEFF))) @PSBoundParameters
