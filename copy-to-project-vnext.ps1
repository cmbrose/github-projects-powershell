using module "./types/board.psm1"
using module "./types/project-vnext.psm1"
using module "./types/item-content.psm1"

[CmdletBinding()]
param(
    # The id number of the source project to copy from
    [int]$srcProject,
    # ProjectVNext, OrgBoard, RepoBoard. Default is ProjectVNext if not set.
    [string]$srcType,
    # The source repository name. Used only if -srcType is RepoBoard.
    [string]$srcRepoName=$null,
    # The id number of the destination project to copy to
    [int]$destProject,
    # The GitHub organization name the projects are in (note: we cannot copy between organizations)
    [string]$org,
    # The GitHub token with org:read and org:write scopes
    [string]$token,
    # Optional list of fields to skip copying from source to destination
    [string[]]$ignoredFields=@(),
    # Specifies the handling for field options which can't be mapped to the destination (because they don't exist there).
    # By default, copying will error out if a field can't be mapped. If set, then options which can't be mapped are simply skipped.
    # Note: it is always OK if the destination project has more options than the source, provided those options are a superset of the source options.
    [switch]$ignoreMissingFieldOptions,
    # Specifies the handling for field options which already have a value in the destination. By default values are not overridden. If set, they will be.
    [switch]$overrideExistingFieldValues,
    # Additional fields to add to the destination project which don't exist in the source. Useful for using this tool to merge projects and adding a de-duping column.
    [HashTable]$additionalFieldValues=$null,
    # Mapping of source to destination Field names in case some names do not match. Only source Fields which do not have a destination Field of the same name need to be given.
    [HashTable]$srcToDestFieldNameMap=@{},
    # Specifies the handling of items with a "Done" value for the Status Field. By default they are processed normally. If set, they are skipped.
    [switch]$ignoreDoneItems
)

Import-Module "./common/client.psm1" -Verbose:$false

function Get-FakeItemContentId{
    [CmdletBinding()]
    [OutputType([Project])]
    param(
        [string]$repo,
        [int]$number
    )

    "fake_item_content_$($repo)_$($number)"
}

function ConvertBoardTo-Project {
    [CmdletBinding()]
    [OutputType([Project])]
    param(
        [Board]$board
    )

    $field = [ProjectField]::new("fake_field_Status", "Status", @())

    $items = @()
    
    $board.columns | ForEach-Object {
        $column = $_

        $fieldOptionId = "fake_field_option_$($column.id)"

        $nextItems = $column.cards | ForEach-Object {
            if ($_.content.id) {
                return [ProjectItem]::new(
                    "fake_project_item_$($_.id)",
                    $_.content,
                    [ProjectFieldValue]::new($field.id, $fieldOptionId)
                )
            } elseif ($_.note) {
                $parseResult = $_.note | Select-String -Pattern "^(https?://)github.com/([^/]+/[^/]+)/(issues|pulls)/(\d+)$"
                if (-not $parseResult.Matches.Success) {
                    return
                }

                $repo = $parseResult.Matches.Groups[2].Value
                $type = $parseResult.Matches.Groups[3].Value
                $number = $parseResult.Matches.Groups[4].Value

                $content = [ItemContent]::new(
                    (Get-FakeItemContentId -repo $repo -number $number),
                    $number,
                    $repo,
                    $type,
                    "mock-author",
                    "mock-title",
                    "mock-body",
                    "mock-created-at",
                    $false,
                    $null,
                    $null
                )

                return [ProjectItem]::new(
                    "fake_project_item_$($_.note.GetHashCode())",
                    $content,
                    [ProjectFieldValue]::new($field.id, $fieldOptionId)
                )
            }
        }

        # If the column had no items, skip adding a Status option for it
        if ($nextItems.count -eq 0) {
            return
        }

        $field.options += [ProjectFieldOption]::new($fieldOptionId, $column.name)

        $items += $nextItems
    }

    [Project]::new(
        "fake_project_$($board.id)",
        "fake_project_$($board.id)",
        $field,
        $items,
        $null # client - not used by the fake project 
    )
}

function Get-SourceToDestFieldMap {
    [CmdletBinding()]
    [OutputType([HashTable])]
    param(
        [Project]$srcProject,
        [Project]$destProject
    )

    Write-Verbose "Mapping project fields..."
    $srcToDestFieldMap = @{}
    $unmatchedFields = @()
    $srcProject.fields | ForEach-Object {
        $srcField = $_

        if ($ignoredFields | Where-Object { $_ -eq $srcField.name }) {
            return
        }

        $targetDestFieldName = $srcField.name
        if ($srcToDestFieldNameMap -and $srcToDestFieldNameMap[$srcField.name]) {
            $targetDestFieldName = $srcToDestFieldNameMap[$srcField.name]
        }

        $destField = $destProject.fields | Where-Object { $_.name -eq $targetDestFieldName }

        if (-not $destField) {
            Write-Warning "Could not find field '$($targetDestFieldName)' in the destination project"
            $unmatchedFields += $srcField.name
            return
        }

        $srcToDestFieldOptionMap = $null
        
        if ($srcField.options -or $destField.options) {
            if  (-not $srcField.options) {
                Write-Warning "Could not map field '$($srcField.name)' - destination field is single-select and source is not"
                $unmatchedFields += $srcField.name
                return
            }

            if  (-not $destField.options) {
                Write-Warning "Could not map field '$($srcField.name)' - source field is single-select and destination is not"
                $unmatchedFields += $srcField.name
                return
            }

            # We only need to confirm that all the source field options map to a destination field option.
            # The destination could have more options, but that's fine.
            $srcToDestFieldOptionMap = @{}
            $unmatchedFieldOptions = @()
            $srcField.options | ForEach-Object {
                $srcOpt = $_
                $destOpt = $destField.options | Where-Object { $_.name -eq $srcOpt.name }

                if ($destOpt) {
                    $srcToDestFieldOptionMap[$srcOpt.id] = $destOpt.id
                } else {
                    $unmatchedFieldOptions += $srcOpt.name
                }
            }

            if ($unmatchedFieldOptions.count -ne 0) {
                if (-not $ignoreMissingFieldOptions) {
                    Write-Warning "Could not map field '$($srcField.name)' - source option(s) [$([string]::join(", ", $unmatchedFieldOptions))] not found"
                    $unmatchedFields += $srcField.name
                    return
                } else {
                    Write-Warning "Could not map options [$([string]::join(", ", $unmatchedFieldOptions))] for field '$($srcField.name)'. Items with those values will not have the value set in the destination project."
                }
            }
        }

        $srcToDestFieldMap[$srcField.id] = @{
            id = $destField.id;
            optionValuesMap = $srcToDestFieldOptionMap;
        }
    }
    Write-Verbose "Done mapping Project fields"

    if ($unmatchedFields.count -ne 0) {
        throw "Could not match field(s) [$([string]::join(", ", $unmatchedFields))] in the source project to a field in the destination project"
    }

    $srcToDestFieldMap
}

function Update-ProjectItemFieldValue {
    [CmdletBinding()]
    param(
        [ProjectItem]$item,
        [string]$fieldName,
        [string]$fieldId,
        [string]$value
    )

    $fieldHasValue = $item.HasValueForField($fieldId)
           
    if ($fieldHasValue) {
        if (-not $overrideExistingFieldValues) {
            Write-Verbose "Destination project already has a value for $($fieldName) for $($item.content.repository)#$($item.content.number), will not override"
            return
        } elseif ($value -eq $item.GetFieldValue($fieldId)) {
            # Value didn't change, nothing to do
            return
        } else {
            Write-Verbose "Overriding existing value for $($fieldName) for $($item.content.repository)#$($item.content.number)"
        }
    }        

   $_ = $item.TrySetFieldValue($fieldId, $value)
}

function Copy-Project {
    [CmdletBinding()]
    param(
        [Project]$from,
        [Project]$to
    )

    $srcToDestFieldMap = Get-SourceToDestFieldMap -srcProject $from -destProject $to

    $from.items | ForEach-Object {
        $srcItem = $_

        $itemOrg = $srcItem.content.repository.split('/')[0]
        $isCrossOrg = $itemOrg -ne $org

        # Check if the issue is already on the destination project
        $destItem = $to.items | Where-Object {
            $targetId = $isCrossOrg ? (Get-FakeItemContentId -repo $_.content.repository -number $_.content.number) : $_.content.id
            $srcItem.content.id -eq $targetId
        }

        if (-not $destItem) {
            if ($isCrossOrg) {
                # This is a limitation on the GraphQL API, it's not supported currently
                Write-Warning "Cannot copy $($_.content.repository)#$($_.content.number) because it is in a different org - skipping it"
                return
            }

            if ($ignoreDoneItems -and ($srcItem.GetFieldValue("Status") -eq "Done")) {
                Write-Verbose "Skipping $($_.content.repository)#$($_.content.number) because it is Done"
                return
            }

            $destItem = $to.AddItemByContentId($srcItem.content.id)
        } else {
            Write-Verbose "Destination project already has $($srcItem.content.repository)#$($srcItem.content.number), will not add it again"
        }

        $from.fields | ForEach-Object {
            $srcField = $_

            $srcFieldValue = $srcItem.GetFieldValue($srcField.id)

            $mappedField = $srcToDestFieldMap[$srcField.id]

            if (-not $mappedField) {
                # This means it was an ignored field
                return
            }
         
            Update-ProjectItemFieldValue -item $destItem -fieldName $srcField.name -fieldId $mappedField.id -value $srcFieldValue
        }
    }
}

$client = New-GraphQLClient $token

if ((-not $srcType) -or ($srcType -eq "ProjectVNext")) {
    $src = Get-Project -org $org -projectNumber $srcProject -client $client
} elseif ($srcType -eq "OrgBoard") {
        $board = Get-OrganizationBoard -org $org -boardNumber $srcProject -client $client

    $src = ConvertBoardTo-Project $board
} elseif ($srcType -eq "RepoBoard") {
    if (-not $srcRepoName) {
        throw "srcRepoName argument is required to copy from a repository board"
    }

    $board = Get-RepoBoard -org $org -repoName $srcRepoName -boardNumber $srcProject -client $client

    $src = ConvertBoardTo-Project $board
} else {
    throw "srcType '$srcType' is unrecognized - the options are [ProjectVNext, OrgBoard, RepoBoard]"
}

$dest = Get-Project -org $org -projectNumber $destProject -client $client

Copy-Project -from $src -to $dest

if ($additionalFieldValues) {
    $additionalFieldValues.keys | ForEach-Object {
        $fieldName = $_
        $fieldValue = $additionalFieldValues[$_]

        $destField = $dest.fields | Where-Object { $_.name -eq $fieldName }
        if (-not $destField) {
            throw "Could not find field '$fieldName' in the destination project"
        }

        if ($destField.options) {
            # Use -like to let the user not need to specify emojis
            $destFieldOption = $destField.options | Where-Object { $_.name -like "*$fieldValue*" }

            if (-not $destFieldOption) {
                throw "Could not find option '$fieldValue' for field '$fieldName' in the destination project"
            } elseif ($destFieldOption.count -ne 1) {
                throw "Field option '$fieldValue' for field '$fieldName' matched multiple options in the destination project - [$([string]::join(", ", $destFieldOption.name))"
            }

            $targetValue = $destFieldOption.id
        } else {
            $targetValue = $fieldValue
        }

        $src.items.content.id | ForEach-Object {
            $srcContentId = $_
            $destItem = $dest.items | Where-Object { $_.content.id -eq $srcContentId }
            if (-not $destItem) {               
                # Item not in the destination, we skipped it earlier for some reason so also ignore here
                return
            }

            Update-ProjectItemFieldValue -item $destItem -fieldName $fieldName -fieldId $destField.id -value $targetValue
        }
    }
}
