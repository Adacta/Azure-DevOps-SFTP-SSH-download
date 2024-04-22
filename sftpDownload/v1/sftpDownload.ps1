[CmdletBinding()]
param()

function Get-FileLocation([string]$fileName)
{
    pushd $PSScriptRoot
    Write-VstsTaskVerbose "Searching for $fileName at $PSScriptRoot"
    $fi = ls -Force -Recurse -File $fileName
    if ($fi -is [System.IO.FileInfo]) {
        $fullName = $fi.FullName
        Write-VstsTaskVerbose "Found $fullName"
    }
    popd

    return $fullName
}

[string]$operationId = [guid]::NewGuid()
Write-VstsTaskVerbose "ApplicationInsights.OperationId: $operationId"
try
{
    if (![string]::IsNullOrWhiteSpace($env:InstrumentationKey))
    {
        $InstrumentationKey = $env:InstrumentationKey
    }

    Add-Type -Path (Get-FileLocation 'System.Diagnostics.DiagnosticSource.dll') -ErrorAction Continue
    Add-Type -Path (Get-FileLocation 'Microsoft.ApplicationInsights.dll') -ErrorAction Continue

    # https://docs.microsoft.com/en-gb/azure/azure-monitor/app/api-custom-events-metrics
    $appInsights = New-Object Microsoft.ApplicationInsights.TelemetryClient -ErrorAction Continue
    if ($appInsights)
    {
        $appInsights.InstrumentationKey = $InstrumentationKey
        #$appInsightsVersion = $appInsights.GetType().Assembly.GetName().Version
        $appInsightsProp = $appInsights.Context.GlobalProperties
        if ($null -eq $appInsightsProp)
        {
            $appInsightsProp = $appInsights.Context.Properties
        }
        Get-ChildItem env:AGENT* |% {
            $appInsightsProp[$_.Key] = $_.Value
        }
        Get-ChildItem env:SYSTEM* |% {
            $appInsightsProp[$_.Key] = $_.Value
        }
        $appInsightsProp["ImageVersion"] = $env.ImageVersion
        $appInsightsProp["PSScriptRoot"] = $PSScriptRoot
        $appInsightsProp["PSVersion"] = $PSVersionTable.PSVersion
        $appInsightsProp["CLRVersion"] = $PSVersionTable.CLRVersion
        if ($PSScriptRoot -match "[\\/]([\d\.]+)[\\/]")
        {
            $appInsights.Context.Component.Version = $Matches.1
        }

        $appInsights.Context.Operation.Name = "sftpDownload"
        $appInsights.Context.Operation.Id = $operationId

        Write-VstsTaskVerbose "ApplicationInsights.StartOperation $operationId"
        #[Microsoft.ApplicationInsights.TelemetryClientExtensions]::StartOperation($appInsights, "sftpDownload", $operationId)
        [type[]]$methodArgs = ($appInsights.GetType(), [string],[string],[string])
        $method = [Microsoft.ApplicationInsights.TelemetryClientExtensions].GetMethod("StartOperation", $methodArgs)
        $genericArgs = [Microsoft.ApplicationInsights.DataContracts.RequestTelemetry]
        $methodGeneric = $method.MakeGenericMethod($genericArgs)
        [object[]]$parameters = ([Microsoft.ApplicationInsights.TelemetryClient]$appInsights, "sftpDownload", $operationId, [string]$null)
        $telemetry = $methodGeneric.Invoke([object]$null, $parameters)
    }
}
catch
{
    Write-Warning "ApplicationInsights: $_"
}

Trace-VstsEnteringInvocation $MyInvocation

function sftpListDirectoryRecursive($sftp, $remoteDir)
{
    $result = [System.Collections.Generic.List[string]]::new()
    $files = $sftp.ListDirectory($remoteDir)
    $files |% {
        #$file = $files[2]
        $file = $_
        if ($file.FullName.EndsWith(".") -or $file.Name.StartsWith("."))
        {
            return
        }
        if ($file.IsDirectory)
        {
            Write-VstsTaskVerbose -Verbose "Listing $($file.FullName)"
            [System.Collections.Generic.List[string]] $subResult = sftpListDirectoryRecursive $sftp $file.FullName
            if ($subResult)
            {
                $result.AddRange($subResult)
            }
        }
        elseif ($file.IsRegularFile)
        {
            $result.Add($file.FullName)
        }
    }

    return $result
}

try {
    if ($env:VerbosePreference)
    {
        Set-Variable VerbosePreference $env:VerbosePreference -ErrorAction Continue
    }
    Import-VstsLocStrings "$PSScriptRoot\Task.json"

    ### check https://github.com/Microsoft/azure-pipelines-task-lib/blob/master/powershell/Docs/UsingOM.md
    ### https://github.com/Microsoft/azure-pipelines-tasks/tree/master/Tasks/DownloadSecureFileV1

    $sshDll = "lib\Renci.SshNet.dll"
    # if (Test-Path $sshDll) {
    #     $sshDll = (Get-Item $sshDll).FullName
    # }
    # else {
    pushd $PSScriptRoot
    Write-VstsTaskVerbose "Searching for Renci.SshNet.dll at $PSScriptRoot"
    $fi = ls -Force -Recurse -File Renci.SshNet.dll
    if ($fi -is [System.IO.FileInfo]) {
        $sshDll = $fi.FullName
        Write-VstsTaskVerbose "Found $sshDll"
    }
    popd
    # }
    Add-Type -Path $sshDll -ErrorAction Stop

    $connectionType = Get-VstsInput -Name connectionType
    switch ($connectionType) {
        "connectedServiceSSH" {
            $sshEndpoint = Get-VstsInput -Name sshEndpoint
            Write-VstsTaskVerbose -Verbose "Using endpoint $sshEndpoint"
            $conn = Get-VstsEndpoint -Name $sshEndpoint -Require
            if ($conn.Data.privateKey) {
                # $conn.Data.privateKey = Get-Content -Raw "test.key"
                $privateKeyStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::Default.GetBytes($conn.Data.privateKey))
                $privateKeyFile = [Renci.SshNet.PrivateKeyFile]::new($privateKeyStream, $conn.Auth.parameters.password)
                $authMethod = [Renci.SshNet.PrivateKeyAuthenticationMethod]::new($conn.Auth.parameters.username, $privateKeyFile)
            }
            elseif ($conn.Auth.parameters.password) {
                $authMethod = [Renci.SshNet.PasswordAuthenticationMethod]::new($conn.Auth.parameters.username, $conn.Auth.parameters.password)
            }
            else {
                $authMethod = [Renci.SshNet.NoneAuthenticationMethod]::new($conn.Auth.parameters.username)
            }
            "Using $connectionType authentication $authMethod"
            $ci = [Renci.SshNet.ConnectionInfo]::new($conn.Data.host, $conn.Data.port, $conn.Auth.parameters.username, $authMethod)
        }
        "hostname" {
            ## For *secureFile* variable type check https://github.com/sboulema/VsixTools/blob/master/src/tasks/signVsix/signVsix.ps1
            ## https://github.com/Microsoft/azure-pipelines-task-lib/tree/master/powershell/Docs/UsingOM.md
            ## https://github.com/Microsoft/azure-pipelines-tasks/blob/master/Tasks/Common/securefiles-common/securefiles-common.ts
            $secureFilePath = Get-VstsInput -Name secureFilePath
            $sshHost = Get-VstsInput -Name sshHost
            $username = Get-VstsInput -Name username
            $password = Get-VstsInput -Name password

            if ($secureFilePath) {
                Write-VstsTaskVerbose -Verbose "Using secureFilePath '$secureFilePath'"
                $privateKeyFile = [Renci.SshNet.PrivateKeyFile]::new($secureFilePath, $password)
                $authMethod = [Renci.SshNet.PrivateKeyAuthenticationMethod]::new($username, $privateKeyFile)
            }
            elseif ($password) {
                $authMethod = [Renci.SshNet.PasswordAuthenticationMethod]::new($username, $password)
            }
            else {
                $authMethod = [Renci.SshNet.NoneAuthenticationMethod]::new($username)
            }
            "Using $connectionType authentication $authMethod"
            $ci = [Renci.SshNet.ConnectionInfo]::new($sshHost, $username, $authMethod)
        }
        Default {throw "Unsupported connectionType '$connectionType'"}
    }

    Write-VstsTaskDebug "SSH AuthenticationMethod: $authMethod"
    Write-VstsTaskVerbose "SSH ConnectionInfo: $ci"

    # Write-Vsts{Task|Log} Error/Warning/ Detail / SetProgress /Verbose/Debug
    try {
        $sftp = [Renci.SshNet.SftpClient]::new($ci)
        $sftp.KeepAliveInterval = "00:05:00"
        Write-VstsTaskDebug "SFTP Connection: $sftp"
        $sftp.Connect()
        Add-Type -LiteralPath $PSScriptRoot\ps_modules\VstsTaskSdk\Minimatch.dll

        $sourcePath = Get-VstsInput -Name sourcePath
        $sourceContents = Get-VstsInput -Name sourceContents

        [System.IO.DirectoryInfo]$targetDirectory = Get-VstsInput -Name target
        $cleanTargetFolder = Get-VstsInput -Name cleanTargetFolder -AsBool
        if ($cleanTargetFolder)
        {
            Write-VstsTaskVerbose -Message "Deleting target folder '$cleanTargetFolder'"
            $targetDirectory.Delete($true)
        }

        if (!$sourceContents)
        {
            throw "sourceContents is empty"
        }

        [System.Collections.Generic.List[string]]$remoteFiles = sftpListDirectoryRecursive $sftp $sourcePath
        $sourcePathInfo = $sftp.Get($sourcePath)
        Write-VstsTaskVerbose -Verbose "Found $($remoteFiles.Count) files at '$sourcePath' ($($sourcePathInfo.FullName))"

        #[System.Collections.Generic.List[string]]$remoteFiles = "test.txt",".dot","new/test
        $sourceContentsArray = $sourceContents.Split(("`r","`n"), [System.StringSplitOptions]::RemoveEmptyEntries)
        $remoteFilesMatch = [System.Collections.Generic.List[string]]::new()
        $sourceContentsArray | % {
            Write-Verbose -Message "Filter: '$_'" -Verbose
            if ($_) {
                $remoteFilesMatch.AddRange([Minimatch.Minimatcher]::Filter($remoteFiles, $_, $null))
            }
        }
        $remoteFilesMatch = [System.Linq.Enumerable]::ToArray([System.Linq.Enumerable]::Distinct($remoteFilesMatch))
        Write-VstsTaskVerbose -Verbose "Match files $($remoteFilesMatch.Length) for $sourceContentsArray"

        $totalSourceFiles = 0.01 * $remoteFilesMatch.Length
        $i = 0
        $remoteFilesMatch | % {
            $i++
            $remoteFile = $_

            #$relPath = $fi.Directory.FullName.Remove(0, $di.FullName.Length)
            #$relPath = $relPath.Replace('\', '/').Replace('//', '/')
            $relativeFilename = $remoteFile.Remove(0, $sourcePathInfo.FullName.Length)
            [System.IO.FileInfo]$targetFilename = Join-Path $targetDirectory.FullName $relativeFilename

            Write-VstsSetProgress -Percent ([int]($i / $totalSourceFiles)) -CurrentOperation "File $remoteFile to $($targetFilename.FullName)"

            $targetFilename.Directory.Create()
            [System.IO.FileInfo]$tempFi = Join-Path $targetFilename.Directory.FullName ([System.IO.Path]::GetRandomFileName())
            $file = $tempFi.OpenWrite()
            $sftp.DownloadFile($remoteFile, $file)
            $file.Dispose()
            $file = $null

            Move-Item $tempFi.FullName $targetFilename.FullName -Force
        }
        #Write-Host "##vso[task.setvariable variable=ProcessedFilesCount;isSecret=false;isOutput=true;]999"
        Set-VstsTaskVariable -Name ProcessedFilesCount -Value $i

        #$stopAt = [datetime]::UtcNow.AddSeconds(20)
        #$i=0
        #while ($stopAt -gt [datetime]::UtcNow) {
        #    sleep -Milliseconds 20
        #    $i++
        #    Write-VstsTaskVerbose -Message "Stream $i"
        #    Write-VstsSetProgress -Percent ($i/10) -CurrentOperation "File $i"
        #}
        #Write-VstsSetResult "Succeeded"
    }
    finally {
        $sftp.Disconnect()
        $sftp.Dispose()
    }
}
finally {
    if ($appInsights -and $Error -and $Error[0].Exception)
    {
        $lastException = $Error[0].Exception
        $appInsights.TrackException($lastException)
        if ($telemetry)
        {
            $telemetry.Telemetry.ResponseCode = 500
            $telemetry.Telemetry.Success = $false
        }
    }
    if ($telemetry)
    {
        Write-VstsTaskVerbose "ApplicationInsights.StopOperation $operationId"
        [Microsoft.ApplicationInsights.TelemetryClientExtensions]::StopOperation($appInsights, $telemetry)
    }
    if ($appInsights)
    {
        try
        {
            $appInsights.Flush()
        }
        catch
        {
            Write-VstsTaskVerbose -Verbose "Exception flushing AppInsights $_"
        }
    }
    Trace-VstsLeavingInvocation $MyInvocation
}
