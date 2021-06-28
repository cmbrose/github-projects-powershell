using module "./types/board.psm1"
using module "./types/project-vnext.psm1"
using module "./types/item-content.psm1"

[CmdletBinding()]
param(
    # The id number of the source project to copy from
    [int]$srcProject,
    # ProjectVNext, OrgBoard, RepoBoard
    [string]$srcType,
    [string]$srcRepoName=$null,
    # The id number of the destination project to copy to
    [int]$destProject,
    [string]$destRepoName=$null,
    # The GitHub organization name the projects are in (note: we cannot copy between organizations)
    [string]$org,
    # The GitHub token with org:read and org:write scopes
    [string]$token,
    # Specifies the handling for statuses for items already in the destination. By default statues are not changed. If set, they will be.
    [switch]$overrideExistingStatus,
    [string]$defaultStatus=$null,
    [switch]$ignoreProjectItemsWithoutStatus,
    [switch]$ignoreDoneItems,
    [HashTable]$srcToDestStatusMap=@{},
    [switch]$skipNotes
)

function Convert-ProjectToBoard {
    [CmdletBinding()]
    [OutputType([Board])]
    param(
        [Project]$project
    )

    $board = [Board]::new(
        "fake_org",
        "fake_repo",
        "fake_board_$($project.id)",
        $null # client
    )

    $statusField = $project.GetField("Status")
    
    $board.columns = $statusField.options | ForEach-Object {
        [BoardColumn]::new(
            "fake_column_$($_.id)",
            $_.name
        )
    }

    $failedToMapItems = @()

    $project.items | ForEach-Object {
        $status = $_.GetFieldValue("Status")

        if (-not $status -or $status -eq "") {
            if ($defaultStatus) {
                $status = $defaultStatus
            } else {
                if (-not $ignoreProjectItemsWithoutStatus) {
                    $failedToMapItems += $_
                }
                return
            }
        }

        $board.GetColumn($status).cards += [BoardCard]::new(
            "fake_card_$($_.id)",
            $null,
            $_.content
        )
    }

    if ($failedToMapItems.length -ne 0) {
        throw "$($failedToMapItems.length) are missing a Status value in the source Project"
    }

    $board
}

function Copy-Board {
    [CmdletBinding()]
    param(
        [Board]$from,
        [Board]$to
    )

    $fullStatusMap = @{}
    $failedToMapColumns = @()

    $from.columns | ForEach-Object {
        $srcColumn = $_

        if ($ignoreDoneItems -and ($srcColumn.name -eq "Done")) {
            # We'll report this skip later
            return
        }

        $targetStatus = $srcColumn.name

        if ($srcToDestStatusMap -and $srcToDestStatusMap[$targetStatus]) {
            $targetStatus = $srcToDestStatusMap[$targetStatus]
        }

        $targetColumn = $dest.GetColumn($targetStatus)
        if (-not $targetColumn) {
            $failedToMapColumns += $srcColumn.name
            return
        }

        $fullStatusMap[$srcColumn.name] = $targetStatus
    }

    if ($failedToMapColumns.length -ne 0) {
        throw "Failed to map source Status(es) [$([string]::Join(", ", $failedToMapColumns))] to the destination board"
    }

    $from.columns | ForEach-Object {
        $srcColumn = $_

        if ($ignoreDoneItems -and ($srcColumn.name -eq "Done")) {
            Write-Verbose "Skipping source Done column"
            return
        }

        $targetStatus = $fullStatusMap[$srcColumn.name]

        $srcColumn.cards | ForEach-Object {
            $srcCard = $_

            if ($srcCard.content.id) {
                # Content card
                try {
                    $_ = $dest.AddContentToColumn($srcCard.content, $targetStatus, $overrideExistingStatus)
                } catch {
                    Write-Verbose "Destination board already contains $($srcCard.content.repository)#$($srcCard.content.number), will not override status"
                }
            } else {
                # Note card

                if ($skipNotes) {
                    return
                }

                try {
                    $_ = $dest.AddNoteToColumn($srcCard.note, $targetStatus, $overrideExistingStatus)
                } catch {
                    $trunc = $srcCard.note.Substring(0, [Math]::Min(103, $srcCard.note.length))
                    if ($trunc.length -ne $srcCard.length) {
                        $trunc = $trunc.Substring(0, 100) + "..."
                    }

                    Write-Verbose "Destination board already contains note '$trunc', will not override status"
                }
            }
        }
    }
}

Import-Module "./common/client.psm1" -Verbose:$false
$client = New-GraphQLClient $token

if ((-not $srcType) -or ($srcType -eq "ProjectVNext")) {
    $project = Get-Project -org $org -projectNumber $srcProject -client $client
    $src = Convert-ProjectToBoard $project
} elseif ($srcType -eq "OrgBoard") {
    $src = Get-OrganizationBoard -org $org -boardNumber $srcProject -client $client
} elseif ($srcType -eq "RepoBoard") {
    if (-not $srcRepoName) {
        throw "srcRepoName argument is required to copy from a repository board"
    }

    $src = Get-RepoBoard -org $org -repoName $srcRepoName -boardNumber $srcProject -client $client
} else {
    throw "srcType '$srcType' is unrecognized - the options are [ProjectVNext, OrgBoard, RepoBoard]"
}

if ($destRepoName) {
    $dest = Get-RepoBoard -org $org -repoName $destRepoName -boardNumber $destProject -client $client
} else {
    $dest = Get-OrganizationBoard -org $org -boardNumber $destProject -client $client
}

Copy-Board -from $src -to $dest