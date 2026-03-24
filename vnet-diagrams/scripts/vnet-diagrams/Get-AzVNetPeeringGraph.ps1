[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [ValidateSet("mermaid", "graphviz", "both")]
    [string]$Format = "both",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [string]$GraphName = "azure-vnet-peerings"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-VnetPartsFromResourceId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $pattern = "^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Network/virtualNetworks/(?<vnet>[^/]+)$"
    $match = [regex]::Match($ResourceId, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if (-not $match.Success) {
        return $null
    }

    return [pscustomobject]@{
        SubscriptionId = $match.Groups["sub"].Value
        ResourceGroup  = $match.Groups["rg"].Value
        VnetName       = $match.Groups["vnet"].Value
    }
}

function Get-SafeNodeId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $safe = $Text -replace "[^A-Za-z0-9_]", "_"
    if ($safe -match "^[0-9]") {
        $safe = "n_$safe"
    }

    return $safe
}

function Escape-MermaidLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return ($Text -replace '"', "'")
}

function Escape-DotLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return ($Text -replace '"', '\"')
}

function Build-Mermaid {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Nodes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edges
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("graph LR")

    foreach ($node in $Nodes.Values | Sort-Object -Property DisplayLabel) {
        $label = Escape-MermaidLabel -Text $node.DisplayLabel
        $lines.Add('    ' + $node.NodeId + '["' + $label + '"]')
    }

    foreach ($edge in $Edges) {
        $edgeLabel = Escape-MermaidLabel -Text $edge.PeeringName
        $lines.Add('    ' + $edge.FromNodeId + ' -- "' + $edgeLabel + '" --> ' + $edge.ToNodeId)
    }

    return $lines -join [Environment]::NewLine
}

function Build-Graphviz {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Nodes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edges,

        [Parameter(Mandatory = $true)]
        [string]$GraphName
    )

    $safeGraphName = Get-SafeNodeId -Text $GraphName
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("digraph $safeGraphName {")
    $lines.Add("    rankdir=LR;")
    $lines.Add("    node [shape=box, style=rounded];")

    foreach ($node in $Nodes.Values | Sort-Object -Property DisplayLabel) {
        $label = Escape-DotLabel -Text $node.DisplayLabel
        $lines.Add('    "' + $node.NodeId + '" [label="' + $label + '"];')
    }

    foreach ($edge in $Edges) {
        $edgeLabel = Escape-DotLabel -Text $edge.PeeringName
        $lines.Add('    "' + $edge.FromNodeId + '" -> "' + $edge.ToNodeId + '" [label="' + $edgeLabel + '"];')
    }

    $lines.Add("}")
    return $lines -join [Environment]::NewLine
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az PowerShell modules are not installed. Install with: Install-Module Az -Scope CurrentUser"
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

$null = Connect-AzAccount -ErrorAction Stop

$nodes = @{}
$edges = [System.Collections.Generic.List[object]]::new()
$nextNodeId = 1

foreach ($subscriptionId in $SubscriptionIds) {
    Write-Host "Scanning subscription: $subscriptionId"
    $null = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

    $vnets = Get-AzVirtualNetwork -ErrorAction Stop
    foreach ($vnet in $vnets) {
        $vnetParts = Get-VnetPartsFromResourceId -ResourceId $vnet.Id
        if ($null -eq $vnetParts) {
            continue
        }

        $nodeKey = $vnet.Id.ToLowerInvariant()
        if (-not $nodes.ContainsKey($nodeKey)) {
            $nodeId = "n$nextNodeId"
            $nextNodeId++
            $nodes[$nodeKey] = [pscustomobject]@{
                NodeId       = $nodeId
                DisplayLabel = "$($vnetParts.SubscriptionId)`n$($vnetParts.ResourceGroup)/$($vnetParts.VnetName)"
                ResourceId   = $vnet.Id
            }
        }

        foreach ($peering in $vnet.VirtualNetworkPeerings) {
            if ([string]::IsNullOrWhiteSpace($peering.RemoteVirtualNetwork.Id)) {
                continue
            }

            $remoteParts = Get-VnetPartsFromResourceId -ResourceId $peering.RemoteVirtualNetwork.Id
            if ($null -eq $remoteParts) {
                continue
            }

            $remoteKey = $peering.RemoteVirtualNetwork.Id.ToLowerInvariant()
            if (-not $nodes.ContainsKey($remoteKey)) {
                $remoteNodeId = "n$nextNodeId"
                $nextNodeId++
                $nodes[$remoteKey] = [pscustomobject]@{
                    NodeId       = $remoteNodeId
                    DisplayLabel = "$($remoteParts.SubscriptionId)`n$($remoteParts.ResourceGroup)/$($remoteParts.VnetName)"
                    ResourceId   = $peering.RemoteVirtualNetwork.Id
                }
            }

            $edges.Add([pscustomobject]@{
                FromNodeId  = $nodes[$nodeKey].NodeId
                ToNodeId    = $nodes[$remoteKey].NodeId
                PeeringName = $peering.Name
            })
        }
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if ($Format -in @("mermaid", "both")) {
    $mermaidContent = Build-Mermaid -Nodes $nodes -Edges $edges
    $mermaidPath = Join-Path $OutputPath "$GraphName-$timestamp.mmd"
    Set-Content -Path $mermaidPath -Value $mermaidContent -Encoding UTF8
    Write-Host "Mermaid file written: $mermaidPath"
}

if ($Format -in @("graphviz", "both")) {
    $dotContent = Build-Graphviz -Nodes $nodes -Edges $edges -GraphName $GraphName
    $dotPath = Join-Path $OutputPath "$GraphName-$timestamp.dot"
    Set-Content -Path $dotPath -Value $dotContent -Encoding UTF8
    Write-Host "Graphviz DOT file written: $dotPath"
}

Write-Host "Done. Nodes: $($nodes.Count), Edges: $($edges.Count)"
