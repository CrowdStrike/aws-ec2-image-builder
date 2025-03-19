<#
.SYNOPSIS
Wrapper script to deploy and prepare CrowdStrike Falcon on Windows for Image Builder
.DESCRIPTION
This script serves as a wrapper to download and execute the Falcon installation script
for Windows systems in EC2 Image Builder pipelines.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('SecretsManager', 'ParameterStore')]
    [string] $SecretStorageMethod,

    [Parameter(Mandatory = $true)]
    [string] $AWSRegion,

    [Parameter(Mandatory = $false)]
    [string] $SecretsManagerSecretName,

    [Parameter(Mandatory = $false)]
    [string] $SSMFalconCloud,

    [Parameter(Mandatory = $false)]
    [string] $SSMFalconClientId,

    [Parameter(Mandatory = $false)]
    [string] $SSMFalconClientSecret,

    [Parameter(Mandatory = $false)]
    [string] $SensorUpdatePolicyName,

    [Parameter(Mandatory = $false)]
    [string] $ProvisioningToken,

    [Parameter(Mandatory = $false)]
    [int] $ProvisioningWaitTime,

    [Parameter(Mandatory = $false)]
    [string] $Tags,

    [Parameter(Mandatory = $false)]
    [string] $ProxyHost,

    [Parameter(Mandatory = $false)]
    [string] $ProxyPort,

    [Parameter(Mandatory = $false)]
    [switch] $ProxyDisable
)

function Write-Log {
    param(
        [string]$Level = "INFO",
        [string]$Message
    )
    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss'))] $Level : $Message"
}

function Test-InputParams {
    $script:inputParams = @(
        "SecretStorageMethod",
        "SecretsManagerSecretName",
        "SSMFalconCloud",
        "SSMFalconClientId",
        "SSMFalconClientSecret",
        "ProvisioningToken",
        "ProvisioningWaitTime",
        "SensorUpdatePolicyName",
        "Tags",
        "ProxyHost",
        "ProxyPort",
        "AWSRegion"
    )

    foreach ($param in $inputParams) {
        $paramValue = Get-Variable -Name $param -ValueOnly
        Write-Log -Message "Processing parameter '$param' with initial value: '$paramValue'"

        # Handle different parameter types
        if ($param -eq "ProvisioningWaitTime") {
            if (![string]::IsNullOrEmpty($paramValue)) {
                if ([int]::TryParse($paramValue, [ref]$null)) {
                    $paramValue = [int]$paramValue
                    Write-Log -Message "Converted ProvisioningWaitTime to integer: $paramValue"
                } else {
                    Write-Log -Level "ERROR" -Message "ProvisioningWaitTime must be a valid integer value"
                    exit 1
                }
            }
        } elseif ($paramValue -is [string]) {
            $paramValue = $paramValue.Trim()
            # Write-Log -Message "Trimmed parameter '$param' to: '$paramValue'"
        }

        Set-Variable -Name $param -Value $paramValue -Scope Script
        Write-Log -Message "Final value set for '$param': '$paramValue'"
    }
}

function Test-StorageMethod {
    if ([string]::IsNullOrEmpty($SecretStorageMethod)) {
        throw "Secret storage method is not provided."
    }

    if ($SecretStorageMethod -notin @('SecretsManager', 'ParameterStore')) {
        throw "Invalid secret storage method: $SecretStorageMethod. Must be either 'SecretsManager' or 'ParameterStore'."
    }
}

function Set-AWSRegion {
    if ([string]::IsNullOrEmpty($AWSRegion)) {
        throw "AWSRegion parameter was not provided."
    }
    Write-Log -Message "Setting AWS CLI region to: $AWSRegion"
    $env:AWS_DEFAULT_REGION = $AWSRegion
}

function Get-SSMParameter {
    param([string]$ParameterName)
    try {
        $parameterValue = aws ssm get-parameter --name $ParameterName --with-decryption --query 'Parameter.Value' --output text
        if ([string]::IsNullOrEmpty($parameterValue)) {
            throw "Failed to retrieve SSM parameter: $ParameterName"
        }
        return $parameterValue
    }
    catch {
        throw "Error getting SSM parameter: $_"
    }
}

function Get-Secret {
    param([string]$SecretName)
    try {
        $secretValue = aws secretsmanager get-secret-value --secret-id $SecretName --query 'SecretString' --output text
        if ([string]::IsNullOrEmpty($secretValue)) {
            throw "Failed to retrieve Secrets Manager secret: $SecretName"
        }
        return $secretValue
    }
    catch {
        throw "Error getting secret: $_"
    }
}

function Get-ValueFromSecret {
    param(
        [string]$Secret,
        [string]$Key
    )
    try {
        $secretObject = $Secret | ConvertFrom-Json
        if ($null -ne $secretObject.$Key) {
            return $secretObject.$Key
        }
        throw "Failed to retrieve '$Key' from secret."
    }
    catch {
        throw "Error parsing secret value: $_"
    }
}
try {
    Test-InputParams
    Test-StorageMethod
    Set-AWSRegion

    switch ($SecretStorageMethod) {
        "SecretsManager" {
            $secret = Get-Secret -SecretName $SecretsManagerSecretName
            $FalconClientId = Get-ValueFromSecret -Secret $secret -Key "ClientId"
            $FalconClientSecret = Get-ValueFromSecret -Secret $secret -Key "ClientSecret"
            $FalconCloud = Get-ValueFromSecret -Secret $secret -Key "Cloud"
        }
        "ParameterStore" {
            $FalconClientId = Get-SSMParameter -ParameterName $SSMFalconClientId
            $FalconClientSecret = Get-SSMParameter -ParameterName $SSMFalconClientSecret
            $FalconCloud = Get-SSMParameter -ParameterName $SSMFalconCloud
        }
    }

    $installScript = "C:\Windows\Temp\falcon-windows-install.ps1"

    $scriptArgs = @(
        "-FalconClientId '$FalconClientId'"
        "-FalconClientSecret '$FalconClientSecret'"
        "-FalconCloud '$FalconCloud'"
        "-SensorUpdatePolicyName '$SensorUpdatePolicyName'"
    )

    if ($ProvisioningToken) { $scriptArgs += "-ProvToken '$ProvisioningToken'" }
    if ($ProvisioningWaitTime) { $scriptArgs += "-ProvWaitTime $ProvisioningWaitTime" }
    if ($Tags) { $scriptArgs += "-Tags '$Tags'" }
    if ($ProxyHost) { $scriptArgs += "-ProxyHost '$ProxyHost'" }
    if ($ProxyPort) { $scriptArgs += "-ProxyPort '$ProxyPort'" }
    if ($ProxyDisable) { $scriptArgs += "-ProxyDisable" }
    # Add install params to configure VM Template
    $scriptArgs += "-InstallParams '/install /quiet /norestart NO_START=1'"

    $scriptCommand = "& '$installScript' $($scriptArgs -join ' ')"
    Write-Log -Message "Executing Falcon sensor installation script..."
    Invoke-Expression $scriptCommand
}
catch {
    Write-Log -Level "ERROR" -Message "Error during execution: $_"
    exit 1
}
