[CmdletBinding()]
param(
    # Accepts subscription objects from Get-AzSubscription, or plain subscription ID strings.
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [object[]]$Subscriptions,

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

function Get-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    return ($Text -replace '[<>:"/\\|?*]', '_')
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

function Convert-ToDiagramModel {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$NodeRecords,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$EdgeRecords
    )

    $diagramNodes = @{}
    $nodeIdByKey = @{}
    $nextNodeId = 1

    foreach ($node in $NodeRecords | Sort-Object -Property DisplayLabel) {
        $nodeId = "n$nextNodeId"
        $nextNodeId++
        $nodeIdByKey[$node.Key] = $nodeId
        $diagramNodes[$node.Key] = [pscustomobject]@{
            NodeId       = $nodeId
            DisplayLabel = $node.DisplayLabel
        }
    }

    $diagramEdges = [System.Collections.Generic.List[object]]::new()
    foreach ($edge in $EdgeRecords) {
        if ($nodeIdByKey.ContainsKey($edge.FromKey) -and $nodeIdByKey.ContainsKey($edge.ToKey)) {
            $diagramEdges.Add([pscustomobject]@{
                FromNodeId  = $nodeIdByKey[$edge.FromKey]
                ToNodeId    = $nodeIdByKey[$edge.ToKey]
                PeeringName = $edge.PeeringName
            })
        }
    }

    return [pscustomobject]@{
        Nodes = $diagramNodes
        Edges = $diagramEdges
    }
}

function Write-DiagramFiles {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Nodes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Edges,

        [Parameter(Mandatory = $true)]
        [ValidateSet("mermaid", "graphviz", "both")]
        [string]$Format,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BaseFileName,

        [Parameter(Mandatory = $true)]
        [string]$GraphTitle
    )

    $writtenFiles = [System.Collections.Generic.List[string]]::new()
    $safeBaseFileName = Get-SafeFileName -Text $BaseFileName

    if ($Format -in @("mermaid", "both")) {
        $mermaidPath = Join-Path $OutputDirectory ($safeBaseFileName + ".mmd")
        $mermaidContent = Build-Mermaid -Nodes $Nodes -Edges $Edges
        Set-Content -Path $mermaidPath -Value $mermaidContent -Encoding UTF8
        $writtenFiles.Add($mermaidPath)
    }

    if ($Format -in @("graphviz", "both")) {
        $dotPath = Join-Path $OutputDirectory ($safeBaseFileName + ".dot")
        $dotContent = Build-Graphviz -Nodes $Nodes -Edges $Edges -GraphName $GraphTitle
        Set-Content -Path $dotPath -Value $dotContent -Encoding UTF8
        $writtenFiles.Add($dotPath)
    }

    return $writtenFiles
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az PowerShell modules are not installed. Install with: Install-Module Az -Scope CurrentUser"
}

if (-not (Get-Module -ListAvailable -Name Az.Network)) {
    throw "Az.Network is not installed. Install with: Install-Module Az -Scope CurrentUser"
}

if (-not (Test-Path -Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

$null = Connect-AzAccount -ErrorAction Stop

$allNodes = @{}
$allEdges = [System.Collections.Generic.List[object]]::new()

# Normalise input: accept subscription objects (Get-AzSubscription) or plain ID strings.
# Pre-populate subscriptionNames from objects so Set-AzContext is not needed just for names.
$subscriptionNames = @{}
$requestedSubscriptionIds = [System.Collections.Generic.List[string]]::new()

foreach ($sub in $Subscriptions) {
    if ($sub -is [string]) {
        $id = $sub.Trim()
        if (-not $requestedSubscriptionIds.Contains($id)) {
            $requestedSubscriptionIds.Add($id)
        }
        # Name will be captured from Set-AzContext during the scan loop
    } else {
        $id = if ($sub.PSObject.Properties['Id']) { $sub.Id } `
              elseif ($sub.PSObject.Properties['SubscriptionId']) { $sub.SubscriptionId } `
              else { $null }
        $name = if ($sub.PSObject.Properties['Name']) { $sub.Name } else { $id }
        if ($null -ne $id) {
            $id = $id.Trim()
            if (-not $requestedSubscriptionIds.Contains($id)) {
                $requestedSubscriptionIds.Add($id)
            }
            $subscriptionNames[$id.ToLowerInvariant()] = $name
        }
    }
}

$requestedSubscriptionIds = @($requestedSubscriptionIds | Sort-Object -Unique)

foreach ($subscriptionId in $requestedSubscriptionIds) {
    $context = Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    # Only fill name from context if not already provided by a subscription object
    if (-not $subscriptionNames.ContainsKey($subscriptionId.ToLowerInvariant())) {
        $subscriptionNames[$subscriptionId.ToLowerInvariant()] = $context.Subscription.Name
    }
    Write-Host "Scanning subscription: $($subscriptionNames[$subscriptionId.ToLowerInvariant()]) ($subscriptionId)"

    $vnets = Get-AzVirtualNetwork -ErrorAction Stop
    foreach ($vnet in $vnets) {
        $vnetParts = Get-VnetPartsFromResourceId -ResourceId $vnet.Id
        if ($null -eq $vnetParts) {
            continue
        }

        $nodeKey = $vnet.Id.ToLowerInvariant()
        if (-not $allNodes.ContainsKey($nodeKey)) {
            $subName = if ($subscriptionNames.ContainsKey($vnetParts.SubscriptionId.ToLowerInvariant())) { $subscriptionNames[$vnetParts.SubscriptionId.ToLowerInvariant()] } else { $vnetParts.SubscriptionId }
            $allNodes[$nodeKey] = [pscustomobject]@{
                Key            = $nodeKey
                ResourceId     = $vnet.Id
                SubscriptionId = $vnetParts.SubscriptionId
                SubscriptionName = $subName
                ResourceGroup  = $vnetParts.ResourceGroup
                VnetName       = $vnetParts.VnetName
                DisplayLabel   = "$subName`n$($vnetParts.ResourceGroup)/$($vnetParts.VnetName)"
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
            if (-not $allNodes.ContainsKey($remoteKey)) {
                $remoteSubName = if ($subscriptionNames.ContainsKey($remoteParts.SubscriptionId.ToLowerInvariant())) { $subscriptionNames[$remoteParts.SubscriptionId.ToLowerInvariant()] } else { $remoteParts.SubscriptionId }
                $allNodes[$remoteKey] = [pscustomobject]@{
                    Key            = $remoteKey
                    ResourceId     = $peering.RemoteVirtualNetwork.Id
                    SubscriptionId = $remoteParts.SubscriptionId
                    SubscriptionName = $remoteSubName
                    ResourceGroup  = $remoteParts.ResourceGroup
                    VnetName       = $remoteParts.VnetName
                    DisplayLabel   = "$remoteSubName`n$($remoteParts.ResourceGroup)/$($remoteParts.VnetName)"
                }
            }

            $allEdges.Add([pscustomobject]@{
                FromKey            = $nodeKey
                ToKey              = $remoteKey
                PeeringName        = $peering.Name
                FromSubscriptionId = $vnetParts.SubscriptionId
                ToSubscriptionId   = $remoteParts.SubscriptionId
            })
        }
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDirectory = Join-Path $OutputPath (Get-SafeFileName -Text ($GraphName + "-split-" + $timestamp))
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$manifestRows = [System.Collections.Generic.List[object]]::new()

foreach ($subscriptionId in $requestedSubscriptionIds) {
    $subscriptionNodes = @($allNodes.Values | Where-Object { $_.SubscriptionId -eq $subscriptionId })
    $subscriptionEdges = @($allEdges | Where-Object { $_.FromSubscriptionId -eq $subscriptionId -and $_.ToSubscriptionId -eq $subscriptionId })

    $subDisplayName = if ($subscriptionNames.ContainsKey($subscriptionId.ToLowerInvariant())) { $subscriptionNames[$subscriptionId.ToLowerInvariant()] } else { $subscriptionId }
    $diagramModel = Convert-ToDiagramModel -NodeRecords $subscriptionNodes -EdgeRecords $subscriptionEdges
    $baseFileName = $GraphName + "-subscription-" + (Get-SafeFileName -Text $subDisplayName)
    $graphTitle = $GraphName + " - " + $subDisplayName
    $writtenFiles = Write-DiagramFiles -Nodes $diagramModel.Nodes -Edges $diagramModel.Edges -Format $Format -OutputDirectory $outputDirectory -BaseFileName $baseFileName -GraphTitle $graphTitle

    $manifestRows.Add([pscustomobject]@{
        DiagramType      = "subscription"
        SubscriptionId   = $subscriptionId
        SubscriptionName = $subDisplayName
        NodeCount        = $diagramModel.Nodes.Count
        EdgeCount        = $diagramModel.Edges.Count
        OutputFiles      = ($writtenFiles -join ';')
    })
}

$summaryNodeRecords = @(
    $allNodes.Values |
        Group-Object -Property SubscriptionId |
        Sort-Object -Property Name |
        ForEach-Object {
            $subId = $_.Name
            $subLabel = if ($subscriptionNames.ContainsKey($subId.ToLowerInvariant())) { $subscriptionNames[$subId.ToLowerInvariant()] } else { $subId }
            [pscustomobject]@{
                Key          = $subId
                DisplayLabel = $subLabel
            }
        }
)

$summaryEdgeMap = @{}
foreach ($edge in $allEdges | Where-Object { $_.FromSubscriptionId -ne $_.ToSubscriptionId }) {
    $pair = @($edge.FromSubscriptionId, $edge.ToSubscriptionId) | Sort-Object
    $pairKey = $pair[0] + '|' + $pair[1]

    if (-not $summaryEdgeMap.ContainsKey($pairKey)) {
        $summaryEdgeMap[$pairKey] = [pscustomobject]@{
            FromKey     = $pair[0]
            ToKey       = $pair[1]
            PeeringName = "0 peerings"
            Count       = 0
        }
    }

    $summaryEdgeMap[$pairKey].Count++
    $summaryEdgeMap[$pairKey].PeeringName = "$($summaryEdgeMap[$pairKey].Count) peerings"
}

$summaryEdgeRecords = @($summaryEdgeMap.Values)
$summaryDiagramModel = Convert-ToDiagramModel -NodeRecords $summaryNodeRecords -EdgeRecords $summaryEdgeRecords
$summaryBaseFileName = $GraphName + "-cross-subscriptions"
$summaryGraphTitle = $GraphName + " cross subscriptions"
$summaryWrittenFiles = Write-DiagramFiles -Nodes $summaryDiagramModel.Nodes -Edges $summaryDiagramModel.Edges -Format $Format -OutputDirectory $outputDirectory -BaseFileName $summaryBaseFileName -GraphTitle $summaryGraphTitle

$manifestRows.Add([pscustomobject]@{
    DiagramType    = "cross-subscription"
    Scope          = "all"
    NodeCount      = $summaryDiagramModel.Nodes.Count
    EdgeCount      = $summaryDiagramModel.Edges.Count
    OutputFiles    = ($summaryWrittenFiles -join ';')
})

$manifestPath = Join-Path $outputDirectory "manifest.csv"
$manifestRows | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

Write-Host "Output directory: $outputDirectory"
Write-Host "Manifest written: $manifestPath"
Write-Host "Done. Diagrams: $($manifestRows.Count), VNets: $($allNodes.Count), Peerings: $($allEdges.Count)"
