param(
    [string]$ApplicationInsightsApiKey = $Env:Deployment_Telemetry_Instrumentation_Key,
    [string]$Edition = $Env:SonarQubeEdition,
    [string]$Version = $Env:SonarQubeVersion
)

function TrackTimedEvent {
    param (
        [string]$InstrumentationKey,
        [string]$EventName,
        [scriptblock]$ScriptBlock,
        [Object[]]$ScriptBlockArguments
    )

    [System.Diagnostics.Stopwatch]$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Command -ScriptBlock $ScriptBlock -ArgumentList $ScriptBlockArguments
    $stopwatch.Stop()

    if ($InstrumentationKey) {
        $uniqueId = ''
        if ($Env:WEBSITE_INSTANCE_ID) {
            $uniqueId = $Env:WEBSITE_INSTANCE_ID.substring(5, 15)
        }

        $properties = @{
            "Location"        = $Env:REGION_NAME;
            "SKU"             = $Env:WEBSITE_SKU;
            "Processor Count" = $Env:NUMBER_OF_PROCESSORS;
            "Always On"       = $Env:WEBSITE_SCM_ALWAYS_ON_ENABLED;
            "UID"             = $uniqueId
        }

        $measurements = @{
            'duration (ms)' = $stopwatch.ElapsedMilliseconds
        }

        $body = ConvertTo-Json -Depth 5 -InputObject @{
            name = "Microsoft.ApplicationInsights.Dev.$InstrumentationKey.Event";
            time = [Datetime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss");
            iKey = $InstrumentationKey;
            data = @{
                baseType = "EventData";
                baseData = @{
                    ver          = 2;
                    name         = $EventName;
                    properties   = $properties;
                    measurements = $measurements;
                }
            };
        }

        Invoke-RestMethod -Method POST -Uri "https://dc.services.visualstudio.com/v2/track" -ContentType "application/json" -Body $body | out-null
    }
}

function ParseLatestVersionUrlFromSonarSourceHtml {
    param (
        [string]$Html,
        [string]$FileNamePrefix
    )

    # Match each relevant zip line and extract timestamp and URL
    $pattern = @"
    (?<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z)\s+\S+\s+<a href="(?<url>https://[^"]+?$FileNamePrefix[^"]+?\.zip)"
"@

    $zipRegex = [regex]::new($pattern)
    $matches = $zipRegex.Matches($Html)

    # Parse matches into objects
    $releases = foreach ($match in $matches) {
        [PSCustomObject]@{
            Timestamp = [datetime]::Parse($match.Groups['timestamp'].Value)
            Url       = $match.Groups['url'].Value
        }
    }

    # Select the latest based on timestamp
    $latest = $releases | Sort-Object Timestamp -Descending | Select-Object -First 1

    return $latest.Url
}

$env:Edition = 'Developer'
$env:Version = 'Latest'

TrackTimedEvent -InstrumentationKey $ApplicationInsightsApiKey -EventName 'Download And Extract Binaries' -ScriptBlock {
    Write-Output 'Copy wwwroot folder'
    xcopy wwwroot ..\wwwroot /YI

    Write-Output 'Setting Security to TLS 1.2'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Output 'Prevent the progress meter from trying to access the console'
    $global:progressPreference = 'SilentlyContinue'

    if (!$Edition) {
        $Edition = 'Community'
    }

    $downloadFolder = 'Distribution/sonarqube' # Community Edition
    $fileNamePrefix = 'sonarqube' # Community Edition
    switch ($Edition) {
        'Developer' {
            Write-Output 'Using Developer edition'
            $downloadFolder = 'CommercialDistribution/sonarqube-developer'
            $fileNamePrefix = 'sonarqube-developer'
        }
        'Enterprise' {
            $downloadFolder = 'CommercialDistribution/sonarqube-enterprise'
            $fileNamePrefix = 'sonarqube-enterprise'
        }
        'Data Center' {
            $downloadFolder = 'CommercialDistribution/sonarqube-datacenter'
            $fileNamePrefix = 'sonarqube-datacenter'
        }
    }

    $fileName = "$fileNamePrefix-$Version.zip"
    $downloadUri = "https://binaries.sonarsource.com/$downloadFolder/$fileName"

    if (!$Version -or ($Version -ieq 'Latest')) {
        Write-Output 'Searching for latest version'
        $sonarSourceUrl = "https://binaries.sonarsource.com/?prefix=$downloadFolder" # The problem here is that this page runs javascript which fetches the list of versions it loads in the HTML
        Write-Output "Loading $sonarSourceUrl"
        $sonarSourceHtml = (Invoke-WebRequest -Uri $sonarSourceUrl -UseBasicParsing).Content
        Write-Output "HTML: $sonarSourceHtml"
        $downloadUri = ParseLatestVersionUrlFromSonarSourceHtml -Html $sonarSourceHtml -FileNamePrefix $fileNamePrefix
        $fileName = [System.IO.Path]::GetFileName($downloadUri)
        Write-Output "Found latest version at $downloadUri"
    }

    if (!$downloadUri -or !$fileName) {
        throw 'Could not get download uri or filename.'
    }

    Write-Output "Downloading '$downloadUri'"
    $outputFile = "..\wwwroot\$fileName"
    Invoke-WebRequest -Uri $downloadUri -OutFile $outputFile -UseBasicParsing
    Write-Output 'Done downloading file'

    TrackTimedEvent -InstrumentationKey $ApplicationInsightsApiKey -EventName 'Extract Binaries' -ScriptBlockArguments $outputFile -ScriptBlock {
        param([string]$outputFile)
        Write-Output 'Extracting zip'
        Expand-Archive -Path $outputFile -DestinationPath '..\wwwroot' -Force
        Write-Output 'Extraction complete'
    }
}
