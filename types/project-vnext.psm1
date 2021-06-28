using module "./graphql-object-base.psm1"
using module "./item-content.psm1"
using module "../common/client.psm1"
. (Join-Path $PSScriptRoot .. common constants.ps1)

class Project: GraphQLObjectBase {
    [ProjectField[]]$Fields

    [ProjectItem[]]$Items

    hidden [GraphQLClient]$client

    Project(
        [string]$id,
        [ProjectField[]]$fields,
        [ProjectItem[]]$items,
        [GraphQLClient]$client
    ) {
        $this.id = $id
        $this.fields = $fields | ForEach-Object { $_ }
        $this.items = $items | ForEach-Object { $_.SetParent($this); $_ }
        $this.client = $client
    }

    [ProjectField]GetField(
        [string]$fieldNameOrId
    ) {
        return $this.fields 
        | Where-Object { ($_.name -eq $fieldNameOrId) -or ($_.id -eq $fieldNameOrId) }
        | Select-Object -First 1
    }

    [void]RemoveItem(
        [ProjectItem]$item
    ) {
        $query = "
            mutation {
                deleteProjectNextItem(
                    input: {
                        projectId: `"$($this.id)`",
                        itemId: `"$($item.id)`"
                    }
                ) {
                    deletedItemId
                }
            }
        "

        try {
            $result = $this.client.MakeRequest($query)
        } catch [Exception] {
            Write-Error "Failed to delete item '$($item.id)' from project"
            throw $_
        }

        $this.items = $this.items | Where-Object { $_.id -ne $item.id }
    }

    [ProjectItem]AddItemByContentId(
        [string]$contentId
    ) {
        $query = "
            mutation {
                addProjectNextItem(
                    input: {
                        projectId: `"$($this.id)`", 
                        contentId: `"$($contentId)`"
                    }
                ) {
                    projectNextItem {
                        $([ProjectItem]::FetchSubQuery)
                    }
                }
            }
        "

        try {
            $result = $this.client.MakeRequest($query)
        } catch [Exception] {
            Write-Error "Failed to add content '$contentId' to project"
            throw $_
        }

        $item = [ProjectItem]::new($result.addProjectNextItem.projectNextItem)

        # If the item already exists in the board the API just returns the same item with the same id
        # In this case, remove the item that already exists
        $this.items = $this.items | Where-Object { $_.id -ne $item.id }

        $item.SetParent($this)
        $this.items += $item

        return $item
    }
}

class ProjectItem: GraphQLObjectBase {
    # The Issue/PR this corresponds to
    [ItemContent]$Content

    [ProjectFieldValue[]]$FieldValues

    hidden [Project]$Parent

    ProjectItem(
        [string]$id,
        [ItemContent]$content,
        [ProjectFieldValue[]]$fieldValues
    ) {
        $this.id = $id
        $this.content = $content
        $this.fieldValues = $fieldValues
    }

    # Constructor from value returned by $FetchSubQuery
    ProjectItem(
        $queryResult
    ) {
        $this.id = $queryResult.id
        $this.content = [ItemContent]::new($queryResult.content)

        $this.fieldValues = $queryResult.fieldValues.edges.node | ForEach-Object {
            $fieldId = $_.projectField.id

            [ProjectFieldValue]::new($fieldId, $_.value)
        }
    }

    [void]SetParent(
        [Project]$parent
    ) {
        $this.parent = $parent
    }

    [bool]HasValueForField(
        [string]$fieldNameOrId
    ) {
        $value = $this.GetFieldValue($fieldNameOrId)

        return $null -ne $value
    }

    [string]GetFieldValue(
        [string]$fieldNameOrId
    ) {
        $field = $this.parent.GetField($fieldNameOrId)
        if (-not $field) {
            return $null
        }

        $value = $this.fieldValues | Where-Object { $_.fieldId -eq $field.id }

        if (-not $value) {
            return $null
        }

        if ($field.options) {
            $option = $field.GetFieldOption($value.value)
            if (-not $option) {
                return $null
            } else {
                return $option.name
            }
        } else {
            return $value.value
        }
    }

    [bool]TrySetFieldValue(
        [string]$fieldNameOrId,
        [string]$value # NameOrId if option
    ) {
        return $this.TrySetFieldValue($fieldNameOrId, $value, $false)
    }

    [bool]TrySetFieldValue(
        [string]$fieldNameOrId,
        [string]$value, # NameOrId if option,
        [bool]$enableOptionLikeMatching
    ) {
        $field = $this.parent.GetField($fieldNameOrId)
        if (-not $field) {
            return $false
        }

        if (-not $value) {
            $targetValue = ""
        } elseif ($field.options) {
            $option = $field.GetFieldOption($value, $enableOptionLikeMatching)
            if (-not $option) {
                return $false
            }

            $targetValue = $option.id
        } else {
            $targetValue = $value
        }

        $query = "
            mutation (`$value: String!) {
                updateProjectNextItemField(
                    input: {
                        projectId: `"$($this.parent.id)`"
                        itemId: `"$($this.id)`"
                        fieldId: `"$($field.id)`"
                        value: `$value
                    }
                ) {
                    projectNextItem {
                        id
                    }
                }
            }
        "

        $variables = @{
            value = $targetValue;
        }

        try {
            $result = $this.parent.client.MakeRequest($query, $variables)
        } catch [Exception] {
            Write-Error "Failed to set field value for item $($this.id)"
            throw $_
        }

        if ($this.HasValueForField($fieldNameOrId)) {
            $this.fieldValues | Where-Object { $_.fieldId -eq $field.id } | ForEach-Object { $_.value = $targetValue } 
        } else {
            $this.fieldValues += [ProjectFieldValue]::new($field.id, $targetValue)
        }

        return $true
    }

    static [string]$FetchSubQuery = "
        id
        fieldValues(first: $global:maxSupportedProjectFields) {
            edges {
                node {
                    projectField {
                        id
                    }
                    value
                }
            }
        }
        content {
            $([ItemContent]::FetchSubQuery)
        }
    "
}

class ProjectField: GraphQLObjectBase {
    [string]$Name

    [ProjectFieldOption[]]$Options

    ProjectField(
        [string]$id,
        [string]$name,
        [ProjectFieldOption[]]$options=$null
    ) {
        $this.id = $id
        $this.name = $name
        $this.options = $options
    }

    # Constructor from value returned by $FetchSubQuery
    ProjectField($queryResult) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name

        if ($queryResult.settings) {
            $settings = $_.settings | ConvertFrom-Json

            if ($settings.options) {
                $this.options = $settings.options | ForEach-Object {
                    [ProjectFieldOption]::new($_.id, $_.name)
                }
            }
        }
    }

    [ProjectFieldOption]GetFieldOption(
        [string]$optionNameOrId
    ) {
        return $this.GetFieldOption($optionNameOrId, $false)
    }

    [ProjectFieldOption]GetFieldOption(
        [string]$optionNameOrId,
        [bool]$enableNameLikeMatching
    ) {
        if (-not $this.options) {
            return $null
        }

        return $this.options 
        | Where-Object { 
            ($_.name -eq $optionNameOrId) -or
            ($enableNameLikeMatching -and ($_.name -like "*$optionNameOrId*")) -or
            ($_.id -eq $optionNameOrId)
        } | Select-Object -First 1
    }

    static [string]$FetchSubQuery = "
        id
        name
        settings
    "
}

class ProjectFieldOption: GraphQLObjectBase {
    [String]$Name

    ProjectFieldOption(
        [string]$id,
        [string]$name
    ) {
        $this.id = $id
        $this.name = $name
    }
}

class ProjectFieldValue {
    [string]$FieldId

    [string]$Value

    ProjectFieldValue(
        [string]$fieldId,
        [string]$value
    ) {
        $this.fieldId = $fieldId
        $this.value = $value
    }
}

function Get-ProjectItems {
    [CmdletBinding()]
    [OutputType([ProjectItem[]])]
    param(
        [string]$org,
        [int]$projectNumber,
        [GraphQLClient]$client
    )

    begin {
        $pageSize = 100

        $query = "
            query (`$id: Int!, `$org: String!, `$cursor: String!) {
                organization(login: `$org) {
                    projectNext(number: `$id) {
                        items(first: $pageSize, after: `$cursor) {                
                            edges {
                                node {
                                    $([ProjectItem]::FetchSubQuery)
                                }
                            }
                            pageInfo {
                                endCursor
                                hasNextPage
                            }
                        }
                    }
                }
            }
        "

        $variables = @{
            id = $projectNumber;
            org = $org;
            cursor = "";
        }
    }
    process {
        do {        
            $result = $client.MakeRequest($query, $variables)

            $result.organization.projectNext.items.edges.node | ForEach-Object {
                if (-not $_.content) {
                    # Probably a draft, nothing to see here
                    return
                }

                [ProjectItem]::new($_)
            }

            $pageInfo = $result.organization.projectNext.items.pageInfo

            $variables.cursor = $pageInfo.endCursor
        } while ($pageInfo.hasNextPage)
    }
}

function Get-ProjectFields {
    [CmdletBinding()]
    [OutputType([ProjectField[]])]
    param(
        [string]$org,
        [int]$projectNumber,
        [GraphQLClient]$client
    )

    $query = "
        query (`$id: Int!, `$org: String!) {
            organization(login: `$org) {
                projectNext(number: `$id) {
                    fields(first: $global:maxSupportedProjectFields) {
                        edges {
                            node {
                                $([ProjectField]::FetchSubQuery)
                            }
                        }
                        pageInfo {
                            hasNextPage
                        }
                    }
                }
            }
        }
    "

    $variables = @{
        id = $projectNumber;
        org = $org;
    }

    $result = $client.MakeRequest($query, $variables)

    if ($result.organization.projectNext.fields.pageInfo.hasNextPage) {
        throw "Could not fetch fields for Project #$projectNumber - it has more than the supported limit of $global:maxSupportedProjectFields fields"
    }

    $result.organization.projectNext.fields.edges.node 
    | ForEach-Object { [ProjectField]::new($_) }
    | Where-Object { -not (Is-IgnoredField $_) }
}

function Is-IgnoredField {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ProjectField]$field
    )

    # These are all set on the content itself and not returned by GraphQL for fieldValues
    ($field.name -eq "Title") -or
    ($field.name -eq "Assignees") -or
    ($field.name -eq "Labels") -or
    ($field.name -eq "Repository") -or
    ($field.name -eq "Milestone")
}

function Get-Project {
    [CmdletBinding()]
    [OutputType([Project])]
    param(
        [string]$org,
        [int]$projectNumber,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    #TODO - this could be added into another query
    $query = "
        query (`$id: Int!, `$org: String!) {
            organization(login: `$org) {
                projectNext(number: `$id) {
                    id
                }
            }
        }
    "

    $variables = @{
        id = $projectNumber;
        org = $org;
    }

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $result = $client.MakeRequest($query, $variables)

    $project = [Project]::new(
        $result.organization.projectNext.id,
        (Get-ProjectFields -org $org -projectNumber $projectNumber -Client $client),
        (Get-ProjectItems -org $org -projectNumber $projectNumber -Client $client),
        $client
    )

    $project
}

Export-ModuleMember -Function "Get-Project"